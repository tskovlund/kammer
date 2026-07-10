defmodule Kammer.Events do
  @moduledoc """
  Events (SPEC §6): timezone-aware single events with all-day/multi-day
  support, member RSVPs, the shared comment engine, email reminders
  (Oban), and ICS export (single events plus secret-token group and user
  feeds).

  All permission decisions are delegated to `Kammer.Authorization`:
  viewing an event requires `:view_group` on its host group; creating
  follows the group's posting policy; editing is for the creator and
  moderators.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Authorization
  alias Kammer.Communities.Community
  alias Kammer.Events.Event
  alias Kammer.Events.EventRsvp
  alias Kammer.Events.EventSeries
  alias Kammer.Events.EventSlot
  alias Kammer.Events.Recurrence
  alias Kammer.Events.SlotClaim
  alias Kammer.Feed
  alias Kammer.Feed.Comment
  alias Kammer.Groups
  alias Kammer.Groups.Group
  alias Kammer.Guests
  alias Kammer.Guests.GuestIdentity
  alias Kammer.Guests.GuestNotifier
  alias Kammer.Guests.Token, as: GuestToken
  alias Kammer.RateLimit
  alias Kammer.Repo
  alias Kammer.Validation

  # Past-events page size (ADR 0027: named constant — a history browse,
  # not a paginated archive today; raising it is a product decision).
  @past_events_limit 30

  # Reminder lead time (SPEC §6): how long before an event's start its
  # reminder email/notification fires. The single source of truth for
  # both `schedule_reminder/1` below and
  # `Kammer.Workers.EventReminderWorker`, which reschedules using the
  # same value when an event's time changes after the reminder job was
  # queued — kept here, not duplicated, so the two can't drift.
  @reminder_lead_hours 24

  @doc """
  Hours before an event's start that its reminder fires (SPEC §6).
  """
  @spec reminder_lead_hours() :: pos_integer()
  def reminder_lead_hours, do: @reminder_lead_hours

  ## Reading

  @doc """
  Fetches an event the actor may view (via its host group), with RSVP
  and comment preloads.
  """
  @spec fetch_viewable_event(User.t() | nil, Community.t(), Ecto.UUID.t()) ::
          {:ok, Event.t()} | {:error, :not_found | :unauthorized}
  def fetch_viewable_event(actor, %Community{} = community, event_id) do
    with %Event{} = event <- get_event(community, event_id) || {:error, :not_found},
         group = Repo.get!(Group, event.group_id),
         :ok <- Authorization.feature_gate(group, :events),
         :ok <- Authorization.authorize(actor, :view_group, group) do
      {:ok, %Event{event | group: group}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches an event by id, raising if it doesn't exist. Unauthenticated
  — for callers that already know the id is valid (e.g. resolving a
  comment's `event_id`) and want the record or a loud failure, not a
  `nil` to handle.
  """
  @spec get_event!(Ecto.UUID.t()) :: Event.t()
  def get_event!(event_id), do: Repo.get!(Event, event_id)

  @doc """
  Fetches a series the actor may manage, for the series/attendance
  page — its creator or a group moderator (SPEC §6: "organizer
  attendance matrix").
  """
  @spec fetch_manageable_series(User.t() | nil, Community.t(), Ecto.UUID.t()) ::
          {:ok, EventSeries.t()} | {:error, :not_found | :unauthorized}
  def fetch_manageable_series(actor, %Community{} = community, series_id) do
    with %EventSeries{} = series <- get_series_in_community(community, series_id),
         group = Repo.get!(Group, series.group_id),
         :ok <- Authorization.feature_gate(group, :events),
         true <- can_manage_series?(actor, series, group) || {:error, :unauthorized} do
      {:ok, series}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_series_in_community(community, series_id) do
    case Ecto.UUID.cast(series_id) do
      {:ok, _uuid} ->
        Repo.one(
          from(series in EventSeries,
            where: series.id == ^series_id and series.community_id == ^community.id
          )
        )

      :error ->
        nil
    end
  end

  defp get_event(community, event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, _uuid} ->
        Repo.one(
          from(event in Event,
            where: event.id == ^event_id and event.community_id == ^community.id,
            preload: ^event_preloads()
          )
        )

      :error ->
        nil
    end
  end

  defp event_preloads do
    slots_query = from(slot in EventSlot, order_by: [asc: slot.position, asc: slot.inserted_at])

    [
      rsvps: [:user, :guest_identity],
      # `:guest_identity` and `:reactions` feed the API serializer (guest
      # authorship and emoji counts); `:replies` feeds the LiveView's
      # nested rendering. The comment association is the flat list of all
      # of an event's comments, so the API serializes it exactly like a
      # post's comments (one level, keyed by `parent_comment_id`).
      comments: [
        :author_user,
        :guest_identity,
        reactions: [],
        replies: [:author_user, :guest_identity]
      ],
      slots: {slots_query, claims: [:user, :guest_identity]}
    ]
  end

  @doc """
  Upcoming events across the groups the actor can see in the community,
  soonest first.
  """
  @spec list_upcoming_events(User.t() | nil, Community.t()) :: [Event.t()]
  def list_upcoming_events(actor, %Community{} = community) do
    list_events(actor, community, :upcoming)
  end

  @doc """
  Past events across the groups the actor can see, most recent first.
  """
  @spec list_past_events(User.t() | nil, Community.t()) :: [Event.t()]
  def list_past_events(actor, %Community{} = community) do
    list_events(actor, community, :past)
  end

  defp list_events(actor, community, direction) do
    now = DateTime.utc_now(:second)

    visible_group_ids =
      actor
      |> Authorization.listable_groups_query(community)
      |> where([group], fragment("'events' = ANY(?)", group.features))
      |> select([group], group.id)
      |> Repo.all()

    base_query =
      from(event in Event,
        where: event.group_id in ^visible_group_ids and is_nil(event.cancelled_at),
        preload: [:group, rsvps: []]
      )

    query =
      case direction do
        :upcoming ->
          from(event in base_query,
            where: event.starts_at >= ^now or event.ends_at >= ^now,
            order_by: [asc: event.starts_at]
          )

        :past ->
          from(event in base_query,
            where: event.starts_at < ^now and (is_nil(event.ends_at) or event.ends_at < ^now),
            order_by: [desc: event.starts_at],
            limit: @past_events_limit
          )
      end

    Repo.all(query)
  end

  ## Writing

  @doc """
  Creates an event in a group. Follows the group's posting policy
  (announcement groups: admins only).
  """
  @spec create_event(User.t(), Group.t(), map()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_event(%User{} = creator, %Group{} = group, attrs) do
    with :ok <- Authorization.feature_gate(group, :events),
         :ok <- Authorization.authorize(creator, :post_in_group, group) do
      attrs =
        attrs
        |> Map.put("community_id", group.community_id)
        |> Map.put("group_id", group.id)
        |> Map.put("created_by_user_id", creator.id)

      with {:ok, event} <- %Event{} |> Event.changeset(attrs) |> Repo.insert() do
        schedule_reminder(event)

        %{"type" => "event", "id" => event.id}
        |> Kammer.Workers.NotificationFanoutWorker.new()
        |> Oban.insert()

        {:ok, %Event{event | group: group}}
      end
    end
  end

  @doc """
  Creates a recurring series (SPEC §6, "constrained RRULE" — weekly,
  biweekly, or monthly, bounded by `recurrence_attrs["until"]`): one
  `EventSeries` row plus one materialized `Event` per occurrence
  (capped at `Kammer.Events.Recurrence.max_occurrences/0`), each
  scheduling its own reminder exactly like a standalone event.
  """
  @spec create_recurring_event(User.t(), Group.t(), map(), map()) ::
          {:ok, [Event.t()]} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_recurring_event(%User{} = creator, %Group{} = group, attrs, recurrence_attrs) do
    with :ok <- Authorization.feature_gate(group, :events),
         :ok <- Authorization.authorize(creator, :post_in_group, group) do
      attrs =
        attrs
        |> Map.put("community_id", group.community_id)
        |> Map.put("group_id", group.id)
        |> Map.put("created_by_user_id", creator.id)

      base_changeset = Event.changeset(%Event{}, attrs)

      series_changeset =
        EventSeries.changeset(%EventSeries{}, %{
          "frequency" => recurrence_attrs["frequency"],
          "until" => recurrence_attrs["until"],
          "community_id" => group.community_id,
          "group_id" => group.id,
          "created_by_user_id" => creator.id
        })

      validate_and_create_series(base_changeset, series_changeset)
    end
  end

  defp validate_and_create_series(base_changeset, series_changeset) do
    cond do
      not base_changeset.valid? ->
        {:error, base_changeset}

      not series_changeset.valid? ->
        {:error, series_changeset}

      empty_series?(base_changeset, series_changeset) ->
        {:error,
         Ecto.Changeset.add_error(series_changeset, :until, "must be on or after the start date")}

      true ->
        do_create_recurring_event(base_changeset, series_changeset)
    end
  end

  defp empty_series?(base_changeset, series_changeset) do
    occurrence_starts(base_changeset, series_changeset) == []
  end

  defp occurrence_starts(base_changeset, series_changeset) do
    starts_at = Ecto.Changeset.get_field(base_changeset, :starts_at)
    timezone = Ecto.Changeset.get_field(base_changeset, :timezone)
    frequency = Ecto.Changeset.get_field(series_changeset, :frequency)
    until = Ecto.Changeset.get_field(series_changeset, :until)

    Recurrence.occurrence_starts(starts_at, frequency, until, timezone)
  end

  # Each occurrence is a struct-literal insert, not a changeset re-cast
  # of user input: `base_changeset` already validated the shared shape
  # once (title, location, and so on), so re-validating it N times over
  # would only re-check things that cannot differ between occurrences.
  defp do_create_recurring_event(base_changeset, series_changeset) do
    base_event = Ecto.Changeset.apply_changes(base_changeset)
    duration = base_event.ends_at && DateTime.diff(base_event.ends_at, base_event.starts_at)
    occurrence_starts = occurrence_starts(base_changeset, series_changeset)

    Repo.transact(fn ->
      with {:ok, series} <- Repo.insert(series_changeset) do
        events =
          Enum.map(occurrence_starts, fn occurrence_start ->
            event =
              Repo.insert!(%Event{
                title: base_event.title,
                description_markdown: base_event.description_markdown,
                starts_at: occurrence_start,
                ends_at: duration && DateTime.add(occurrence_start, duration, :second),
                all_day: base_event.all_day,
                timezone: base_event.timezone,
                location_name: base_event.location_name,
                location_url: base_event.location_url,
                community_id: base_event.community_id,
                group_id: base_event.group_id,
                created_by_user_id: base_event.created_by_user_id,
                series_id: series.id
              })

            schedule_reminder(event)
            event
          end)

        {:ok, events}
      end
    end)
  end

  @doc """
  Updates an event (creator or moderators). Reminder timing follows the
  new start automatically — the reminder worker re-reads the event.
  """
  @spec update_event(User.t(), Event.t(), map()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_event(%User{} = actor, %Event{} = event, attrs) do
    group = Repo.get!(Group, event.group_id)

    if can_manage_event?(actor, event, group) do
      attrs = Map.drop(attrs, ["community_id", "group_id", "created_by_user_id"])

      with {:ok, updated_event} <- event |> Event.changeset(attrs) |> Repo.update() do
        if updated_event.starts_at != event.starts_at, do: schedule_reminder(updated_event)
        {:ok, updated_event}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Deletes an event (creator or moderators).
  """
  @spec delete_event(User.t(), Event.t()) :: {:ok, Event.t()} | {:error, :unauthorized}
  def delete_event(%User{} = actor, %Event{} = event) do
    group = Repo.get!(Group, event.group_id)

    if can_manage_event?(actor, event, group) do
      Repo.delete(event)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Whether the actor may edit/delete the event — its creator or a group
  moderator.
  """
  @spec can_manage_event?(User.t() | nil, Event.t(), Group.t()) :: boolean()
  def can_manage_event?(actor, %Event{} = event, %Group{} = group) do
    Authorization.can_manage_own_resource?(actor, event.created_by_user_id, group)
  end

  @doc """
  Returns a changeset for event forms.
  """
  @spec change_event(Event.t(), map()) :: Ecto.Changeset.t()
  def change_event(%Event{} = event, attrs \\ %{}) do
    Event.changeset(event, attrs)
  end

  ## Recurrence (SPEC §6): "cancel/move one date" per-instance
  ## overrides. Moving is just `update_event/3` on that occurrence's
  ## row — nothing series-specific about changing a date. Cancelling
  ## keeps the row (and its RSVPs/comments) but excludes it from
  ## listings, reminders, and ICS feeds.

  @doc """
  Cancels a single occurrence (creator or moderators). The occurrence
  stays visible directly, with its RSVP and comment history intact.
  """
  @spec cancel_occurrence(User.t(), Event.t()) :: {:ok, Event.t()} | {:error, :unauthorized}
  def cancel_occurrence(%User{} = actor, %Event{} = event) do
    group = Repo.get!(Group, event.group_id)

    if can_manage_event?(actor, event, group) do
      event |> Ecto.Changeset.change(cancelled_at: DateTime.utc_now(:second)) |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Reinstates a cancelled occurrence.
  """
  @spec uncancel_occurrence(User.t(), Event.t()) :: {:ok, Event.t()} | {:error, :unauthorized}
  def uncancel_occurrence(%User{} = actor, %Event{} = event) do
    group = Repo.get!(Group, event.group_id)

    if can_manage_event?(actor, event, group) do
      event |> Ecto.Changeset.change(cancelled_at: nil) |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Whether the actor may manage the series an occurrence belongs to —
  same rule as a single event: its creator or a group moderator.
  """
  @spec can_manage_series?(User.t() | nil, EventSeries.t(), Group.t()) :: boolean()
  def can_manage_series?(actor, %EventSeries{} = series, %Group{} = group) do
    Authorization.can_manage_own_resource?(actor, series.created_by_user_id, group)
  end

  @doc """
  The series an occurrence belongs to, or `nil` for a standalone event.
  """
  @spec get_series(Event.t()) :: EventSeries.t() | nil
  def get_series(%Event{series_id: nil}), do: nil
  def get_series(%Event{series_id: series_id}), do: Repo.get(EventSeries, series_id)

  @doc """
  Every occurrence in a series, soonest first, with RSVPs preloaded.
  """
  @spec list_series_occurrences(EventSeries.t()) :: [Event.t()]
  def list_series_occurrences(%EventSeries{} = series) do
    Repo.all(
      from(event in Event,
        where: event.series_id == ^series.id,
        order_by: [asc: event.starts_at],
        preload: [rsvps: [:user, :guest_identity]]
      )
    )
  end

  @doc """
  The organizer attendance matrix for a series (SPEC §6): every group
  member as a row, every upcoming (not cancelled) occurrence as a
  column, each cell the member's RSVP status for that occurrence (or
  `nil` if they haven't answered). Restricted to whoever manages the
  series.
  """
  @spec attendance_matrix(User.t(), EventSeries.t()) ::
          {:ok,
           %{
             series: EventSeries.t(),
             occurrences: [Event.t()],
             rows: [%{member: User.t(), statuses: %{Ecto.UUID.t() => EventRsvp.status() | nil}}]
           }}
          | {:error, :unauthorized}
  def attendance_matrix(%User{} = actor, %EventSeries{} = series) do
    group = Repo.get!(Group, series.group_id)

    if can_manage_series?(actor, series, group) do
      now = DateTime.utc_now(:second)

      occurrences =
        series
        |> list_series_occurrences()
        |> Enum.reject(& &1.cancelled_at)
        |> Enum.filter(&(DateTime.compare(&1.starts_at, now) != :lt))

      occurrence_ids = Enum.map(occurrences, & &1.id)

      rsvp_by_user_and_occurrence =
        occurrences
        |> Enum.flat_map(& &1.rsvps)
        |> Enum.filter(& &1.user_id)
        |> Map.new(&{{&1.user_id, &1.event_id}, &1.status})

      {:ok, memberships} = Groups.list_members(actor, group)

      rows =
        Enum.map(memberships, fn membership ->
          statuses =
            Map.new(occurrence_ids, fn occurrence_id ->
              status = Map.get(rsvp_by_user_and_occurrence, {membership.user_id, occurrence_id})
              {occurrence_id, status}
            end)

          %{member: membership.user, statuses: statuses}
        end)

      {:ok, %{series: series, occurrences: occurrences, rows: rows}}
    else
      {:error, :unauthorized}
    end
  end

  ## RSVPs

  @doc """
  Sets the actor's RSVP (yes/no/maybe). Group members only.
  """
  @spec rsvp(User.t(), Event.t(), EventRsvp.status()) ::
          {:ok, EventRsvp.t()} | {:error, term()}
  def rsvp(%User{} = actor, %Event{} = event, status) when status in [:yes, :no, :maybe] do
    group = Repo.get!(Group, event.group_id)
    relationship = Authorization.relationship(actor, group)

    if Authorization.can_react?(actor, group, relationship) do
      %EventRsvp{}
      |> EventRsvp.changeset(%{status: status, event_id: event.id, user_id: actor.id})
      |> Repo.insert(
        on_conflict: [set: [status: status, updated_at: DateTime.utc_now(:second)]],
        conflict_target: [:event_id, :user_id],
        returning: true
      )
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  The actor's RSVP for the event, or `nil`.
  """
  @spec get_rsvp(Event.t(), User.t() | nil) :: EventRsvp.t() | nil
  def get_rsvp(%Event{}, nil), do: nil

  def get_rsvp(%Event{} = event, %User{} = user) do
    Repo.get_by(EventRsvp, event_id: event.id, user_id: user.id)
  end

  ## Guest RSVPs (SPEC §6): name + email on public events, no account.
  ## The flow is two signed links: a confirm link proves control of the
  ## email (nothing is recorded before it's followed), and the
  ## confirmation email then carries an ICS file plus a management link
  ## for changing the answer or erasing the guest entirely (SPEC §12).

  @doc """
  First step: validates the request, rate-limits it (per email and IP),
  and emails a signed confirm link. Records nothing yet.

  `confirm_url_fun` receives the signed token and returns the absolute
  URL for the email (the web layer owns URL building).
  """
  @spec request_guest_rsvp(Event.t(), Group.t(), map(), keyword()) ::
          :ok | {:error, :unauthorized | :rate_limited | Ecto.Changeset.t()}
  def request_guest_rsvp(%Event{} = event, %Group{} = group, attrs, opts) do
    changeset = guest_request_changeset(attrs)

    with true <- Authorization.can_guest_rsvp?(group) or {:error, :unauthorized},
         {:ok, request} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:allow, _count} <- RateLimit.hit_guest_email(request.email),
         {:allow, _count} <- RateLimit.hit_guest_ip(opts[:client_ip]) do
      token =
        GuestToken.sign_confirm(%{
          event_id: event.id,
          email: request.email,
          display_name: request.display_name,
          status: request.status
        })

      confirm_url = opts |> Keyword.fetch!(:confirm_url_fun) |> then(& &1.(token))

      GuestNotifier.deliver_confirmation_request(
        request.email,
        request.display_name,
        event,
        confirm_url
      )

      :ok
    else
      {:deny, _retry_after} -> {:error, :rate_limited}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Second step, from the emailed confirm link: records the verified
  identity and the RSVP, and sends the confirmation email (ICS +
  management link built by `manage_url_fun`). Returns the event with
  `:community` preloaded, so callers can build a redirect path
  without their own `Repo` access.
  """
  @spec confirm_guest_rsvp(String.t(), (String.t() -> String.t())) ::
          {:ok, Event.t(), GuestIdentity.t()} | {:error, :invalid}
  def confirm_guest_rsvp(token, manage_url_fun) do
    with {:ok, %{event_id: event_id, email: email, display_name: display_name, status: status}} <-
           GuestToken.verify_confirm(token),
         %Event{} = event <- Repo.get(Event, event_id),
         %Group{} = group <- Repo.get(Group, event.group_id),
         true <- Authorization.can_guest_rsvp?(group),
         {:ok, identity} <- Guests.verify_identity(email, display_name),
         {:ok, _rsvp} <- upsert_guest_rsvp(event, identity, status) do
      manage_token = GuestToken.sign_manage(%{identity_id: identity.id})
      GuestNotifier.deliver_confirmed(identity, event, manage_url_fun.(manage_token))
      {:ok, Repo.preload(event, :community), identity}
    else
      _invalid_or_gone -> {:error, :invalid}
    end
  end

  @doc """
  Changes a guest's answer through their management link. Only answers
  the guest already gave can change — the management page lists exactly
  those; new RSVPs go through the confirm flow.
  """
  @spec update_guest_rsvp(String.t(), Ecto.UUID.t(), EventRsvp.status()) ::
          {:ok, EventRsvp.t()} | {:error, :invalid}
  def update_guest_rsvp(manage_token, event_id, status) when status in [:yes, :no, :maybe] do
    with {:ok, %{identity_id: identity_id}} <- GuestToken.verify_manage(manage_token),
         %GuestIdentity{} = identity <- Guests.get_identity(identity_id),
         %EventRsvp{} = rsvp <-
           Repo.get_by(EventRsvp, event_id: event_id, guest_identity_id: identity.id) do
      rsvp
      |> Ecto.Changeset.change(status: status)
      |> Repo.update()
    else
      _invalid_or_gone -> {:error, :invalid}
    end
  end

  defp upsert_guest_rsvp(%Event{} = event, %GuestIdentity{} = identity, status) do
    %EventRsvp{}
    |> EventRsvp.guest_changeset(%{
      status: status,
      event_id: event.id,
      guest_identity_id: identity.id
    })
    |> Repo.insert(
      on_conflict: [set: [status: status, updated_at: DateTime.utc_now(:second)]],
      conflict_target:
        {:unsafe_fragment, "(event_id, guest_identity_id) WHERE guest_identity_id IS NOT NULL"},
      returning: true
    )
  end

  defp guest_request_changeset(attrs) do
    types = %{
      email: :string,
      display_name: :string,
      status: Ecto.ParameterizedType.init(Ecto.Enum, values: EventRsvp.statuses())
    }

    {%{}, types}
    |> Ecto.Changeset.cast(attrs, Map.keys(types))
    |> Ecto.Changeset.validate_required([:email, :display_name, :status])
    |> Ecto.Changeset.update_change(:email, &String.downcase/1)
    |> Validation.validate_email_format()
    |> Validation.validate_display_name_length()
  end

  ## Signup slots (issue #37, collaborative track #17): "bring cake ×2".
  ## Slots are managed by event managers; claims are one-tap for anyone
  ## who can RSVP, and email-verified for guests (same two-link flow as
  ## guest RSVPs). Capacity is enforced under a row lock — a full slot
  ## refuses, it never overbooks.

  @doc """
  Adds a signup slot to an event (event managers only).
  """
  @spec create_slot(User.t(), Event.t(), map()) ::
          {:ok, EventSlot.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_slot(%User{} = actor, %Event{} = event, attrs) do
    group = Repo.get!(Group, event.group_id)

    if can_manage_event?(actor, event, group) do
      position =
        Repo.one(
          from(slot in EventSlot,
            where: slot.event_id == ^event.id,
            select: coalesce(max(slot.position), -1)
          )
        ) + 1

      %EventSlot{event_id: event.id, position: position}
      |> EventSlot.changeset(Map.drop(attrs, ["position"]))
      |> Repo.insert()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Fetches an event slot by id, or `nil` if it doesn't exist.
  Unauthenticated — callers pass the result to an authorization-checked
  mutator below.
  """
  @spec get_slot(Ecto.UUID.t()) :: EventSlot.t() | nil
  def get_slot(slot_id), do: Repo.get(EventSlot, slot_id)

  @doc """
  Fetches a user's claim on a slot, or `nil` if they haven't claimed
  it. Unauthenticated — callers pass the result to an
  authorization-checked mutator below.
  """
  @spec get_slot_claim(Ecto.UUID.t(), Ecto.UUID.t()) :: SlotClaim.t() | nil
  def get_slot_claim(slot_id, user_id),
    do: Repo.get_by(SlotClaim, slot_id: slot_id, user_id: user_id)

  @doc """
  Deletes a slot and every claim on it (event managers only).
  """
  @spec delete_slot(User.t(), EventSlot.t()) ::
          {:ok, EventSlot.t()} | {:error, :unauthorized}
  def delete_slot(%User{} = actor, %EventSlot{} = slot) do
    event = Repo.get!(Event, slot.event_id)
    group = Repo.get!(Group, event.group_id)

    if can_manage_event?(actor, event, group) do
      Repo.delete(slot)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Claims a slot for a member — anyone who can RSVP to the event. Fails
  with `:slot_full` when capacity is reached (checked under a row lock,
  so concurrent claims never overbook).
  """
  @spec claim_slot(User.t(), EventSlot.t()) ::
          {:ok, SlotClaim.t()} | {:error, :slot_full | :unauthorized | Ecto.Changeset.t()}
  def claim_slot(%User{} = actor, %EventSlot{} = slot) do
    event = Repo.get!(Event, slot.event_id)
    group = Repo.get!(Group, event.group_id)
    relationship = Authorization.relationship(actor, group)

    if Authorization.can_react?(actor, group, relationship) do
      insert_claim(slot, fn locked_slot ->
        SlotClaim.changeset(%SlotClaim{}, %{slot_id: locked_slot.id, user_id: actor.id})
      end)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Releases a claim: your own, or any claim if you manage the event.
  """
  @spec unclaim_slot(User.t(), SlotClaim.t()) ::
          {:ok, SlotClaim.t()} | {:error, :unauthorized}
  def unclaim_slot(%User{} = actor, %SlotClaim{} = claim) do
    slot = Repo.get!(EventSlot, claim.slot_id)
    event = Repo.get!(Event, slot.event_id)
    group = Repo.get!(Group, event.group_id)

    if claim.user_id == actor.id or can_manage_event?(actor, event, group) do
      Repo.delete(claim)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  First step of a guest claim (same shape as guest RSVPs): validates,
  rate-limits, and emails a signed confirm link. Records nothing yet.
  Guests claim on the same policy that lets them RSVP.
  """
  @spec request_guest_claim(EventSlot.t(), Event.t(), Group.t(), map(), keyword()) ::
          :ok | {:error, :unauthorized | :rate_limited | :slot_full | Ecto.Changeset.t()}
  def request_guest_claim(%EventSlot{} = slot, %Event{} = event, %Group{} = group, attrs, opts) do
    changeset = guest_claim_request_changeset(attrs)

    with true <- Authorization.can_guest_rsvp?(group) or {:error, :unauthorized},
         true <- slot.event_id == event.id or {:error, :unauthorized},
         {:ok, request} <- Ecto.Changeset.apply_action(changeset, :insert),
         true <- slot_has_room?(slot) or {:error, :slot_full},
         {:allow, _count} <- RateLimit.hit_guest_email(request.email),
         {:allow, _count} <- RateLimit.hit_guest_ip(opts[:client_ip]) do
      token =
        GuestToken.sign_confirm(%{
          slot_id: slot.id,
          email: request.email,
          display_name: request.display_name
        })

      confirm_url = opts |> Keyword.fetch!(:confirm_url_fun) |> then(& &1.(token))

      GuestNotifier.deliver_claim_confirmation_request(
        request.email,
        request.display_name,
        slot,
        event,
        confirm_url
      )

      :ok
    else
      {:deny, _retry_after} -> {:error, :rate_limited}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Second step, from the emailed confirm link: records the verified
  identity and the claim (capacity re-checked under the lock), and
  sends the confirmation with the guest's management link. Returns
  the event with `:community` preloaded, so callers can build a
  redirect path without their own `Repo` access.
  """
  @spec confirm_guest_claim(String.t(), (String.t() -> String.t())) ::
          {:ok, Event.t(), GuestIdentity.t()} | {:error, :invalid | :slot_full}
  def confirm_guest_claim(token, manage_url_fun) do
    with {:ok, %{slot_id: slot_id, email: email, display_name: display_name}} <-
           GuestToken.verify_confirm(token),
         %EventSlot{} = slot <- Repo.get(EventSlot, slot_id),
         %Event{} = event <- Repo.get(Event, slot.event_id),
         %Group{} = group <- Repo.get(Group, event.group_id),
         true <- Authorization.can_guest_rsvp?(group),
         {:ok, identity} <- Guests.verify_identity(email, display_name),
         {:ok, _claim} <-
           insert_claim(slot, fn locked_slot ->
             SlotClaim.guest_changeset(%SlotClaim{}, %{
               slot_id: locked_slot.id,
               guest_identity_id: identity.id
             })
           end) do
      manage_token = GuestToken.sign_manage(%{identity_id: identity.id})
      GuestNotifier.deliver_claim_confirmed(identity, slot, event, manage_url_fun.(manage_token))
      {:ok, Repo.preload(event, :community), identity}
    else
      {:error, :slot_full} -> {:error, :slot_full}
      _invalid_or_gone -> {:error, :invalid}
    end
  end

  @doc """
  Releases a guest's claim through their signed management link.
  """
  @spec unclaim_slot_by_token(String.t(), Ecto.UUID.t()) ::
          {:ok, SlotClaim.t()} | {:error, :invalid}
  def unclaim_slot_by_token(manage_token, claim_id) do
    with {:ok, %{identity_id: identity_id}} <- GuestToken.verify_manage(manage_token),
         %SlotClaim{guest_identity_id: ^identity_id} = claim <- Repo.get(SlotClaim, claim_id) do
      Repo.delete(claim)
    else
      _invalid_or_gone -> {:error, :invalid}
    end
  end

  # Claims must never exceed capacity: lock the slot row, count, insert.
  # Duplicate claims surface as changeset errors from the partial unique
  # indexes, inside the same transaction.
  defp insert_claim(%EventSlot{} = slot, changeset_fun) do
    Repo.transact(fn ->
      locked_slot =
        Repo.one!(
          from(candidate in EventSlot, where: candidate.id == ^slot.id, lock: "FOR UPDATE")
        )

      claims = Repo.aggregate(from(claim in SlotClaim, where: claim.slot_id == ^slot.id), :count)

      if claims < locked_slot.capacity do
        Repo.insert(changeset_fun.(locked_slot))
      else
        {:error, :slot_full}
      end
    end)
  end

  defp slot_has_room?(%EventSlot{} = slot) do
    claims = Repo.aggregate(from(claim in SlotClaim, where: claim.slot_id == ^slot.id), :count)
    claims < slot.capacity
  end

  defp guest_claim_request_changeset(attrs) do
    types = %{email: :string, display_name: :string}

    {%{}, types}
    |> Ecto.Changeset.cast(attrs, Map.keys(types))
    |> Ecto.Changeset.validate_required([:email, :display_name])
    |> Ecto.Changeset.update_change(:email, &String.downcase/1)
    |> Validation.validate_email_format()
    |> Validation.validate_display_name_length()
  end

  ## Comments — the same engine as posts (ADR 0007)

  @doc """
  Comments on an event, honoring the group's comment policy and the
  one-reply-level rule.
  """
  @spec create_comment(User.t(), Event.t(), map()) ::
          {:ok, Comment.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :rate_limited}
  def create_comment(%User{} = author, %Event{} = event, attrs) do
    group = Repo.get!(Group, event.group_id)
    relationship = Authorization.relationship(author, group)

    cond do
      not Authorization.can?(author, :comment_in_group, group, relationship) or
          not is_nil(event.comment_locked_at) ->
        {:error, :unauthorized}

      true ->
        Feed.create_engine_comment(
          author,
          group,
          relationship,
          %Comment{event_id: event.id},
          attrs
        )
    end
  end

  ## ICS feed tokens (SPEC §6: secret-token URLs)

  @doc """
  The user's ICS feed token, generated on first use.
  """
  @spec ensure_user_ics_token(User.t()) :: String.t()
  def ensure_user_ics_token(%User{ics_token: token}) when is_binary(token), do: token

  def ensure_user_ics_token(%User{} = user) do
    token = generate_token()
    user |> Ecto.Changeset.change(ics_token: token) |> Repo.update!()
    token
  end

  @doc """
  The group's ICS feed token, generated on first use.
  """
  @spec ensure_group_ics_token(Group.t()) :: String.t()
  def ensure_group_ics_token(%Group{ics_token: token}) when is_binary(token), do: token

  def ensure_group_ics_token(%Group{} = group) do
    token = generate_token()
    group |> Ecto.Changeset.change(ics_token: token) |> Repo.update!()
    token
  end

  @doc """
  Events for a group ICS feed token, or `nil` for unknown tokens.
  """
  @spec events_for_group_token(String.t()) :: {Group.t(), [Event.t()]} | nil
  def events_for_group_token(token) when is_binary(token) do
    case Repo.get_by(Group, ics_token: token) do
      nil ->
        nil

      %Group{} = group ->
        if Group.feature_enabled?(group, :events) do
          {group,
           Repo.all(
             from(event in Event,
               where: event.group_id == ^group.id and is_nil(event.cancelled_at),
               order_by: event.starts_at
             )
           )}
        else
          # Feature off ⇒ the feed reads as unknown (ADR 0016: same
          # not-found surface as unauthorized).
          nil
        end
    end
  end

  @doc """
  Merged events for a user ICS feed token (all their member groups), or
  `nil` for unknown tokens.
  """
  @spec events_for_user_token(String.t()) :: {User.t(), [Event.t()]} | nil
  def events_for_user_token(token) when is_binary(token) do
    case Repo.get_by(User, ics_token: token) do
      nil ->
        nil

      %User{} = user ->
        {user,
         Repo.all(
           from(event in Event,
             join: membership in Kammer.Groups.GroupMembership,
             on: membership.group_id == event.group_id,
             join: group in Group,
             on: group.id == event.group_id,
             where: membership.user_id == ^user.id,
             where: fragment("'events' = ANY(?)", group.features),
             where: is_nil(event.cancelled_at),
             order_by: event.starts_at
           )
         )}
    end
  end

  defp generate_token do
    Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  ## Reminders

  defp schedule_reminder(%Event{} = event) do
    reminder_at = DateTime.add(event.starts_at, -@reminder_lead_hours, :hour)

    if DateTime.compare(reminder_at, DateTime.utc_now()) == :gt do
      %{"event_id" => event.id, "starts_at" => DateTime.to_iso8601(event.starts_at)}
      |> Kammer.Workers.EventReminderWorker.new(scheduled_at: reminder_at)
      |> Oban.insert()
    end

    :ok
  end
end
