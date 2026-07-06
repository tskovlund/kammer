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
  alias Kammer.Feed.Comment
  alias Kammer.Groups.Group
  alias Kammer.Guests
  alias Kammer.Guests.GuestIdentity
  alias Kammer.Guests.GuestNotifier
  alias Kammer.Guests.Token, as: GuestToken
  alias Kammer.RateLimit
  alias Kammer.Repo

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

  defp get_event(community, event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, _uuid} ->
        Repo.one(
          from(event in Event,
            where: event.id == ^event_id and event.community_id == ^community.id,
            preload: [
              rsvps: [:user, :guest_identity],
              comments: [:author_user, replies: [:author_user]]
            ]
          )
        )

      :error ->
        nil
    end
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
        where: event.group_id in ^visible_group_ids,
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
            limit: 30
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
  def can_manage_event?(nil, %Event{}, %Group{}), do: false

  def can_manage_event?(%User{} = actor, %Event{} = event, %Group{} = group) do
    event.created_by_user_id == actor.id or Authorization.can?(actor, :moderate_group, group)
  end

  @doc """
  Returns a changeset for event forms.
  """
  @spec change_event(Event.t(), map()) :: Ecto.Changeset.t()
  def change_event(%Event{} = event, attrs \\ %{}) do
    Event.changeset(event, attrs)
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
  management link built by `manage_url_fun`).
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
      manage_token = GuestToken.sign_manage(%{identity_id: identity.id, event_id: event.id})
      GuestNotifier.deliver_confirmed(identity, event, manage_url_fun.(manage_token))
      {:ok, event, identity}
    else
      _invalid_or_gone -> {:error, :invalid}
    end
  end

  @doc """
  Loads the state behind a management link: the event, the guest, and
  their current RSVP.
  """
  @spec fetch_guest_rsvp(String.t()) ::
          {:ok, %{event: Event.t(), identity: GuestIdentity.t(), rsvp: EventRsvp.t() | nil}}
          | {:error, :invalid}
  def fetch_guest_rsvp(manage_token) do
    with {:ok, %{identity_id: identity_id, event_id: event_id}} <-
           GuestToken.verify_manage(manage_token),
         %GuestIdentity{} = identity <- Guests.get_identity(identity_id),
         %Event{} = event <- Repo.get(Event, event_id) do
      rsvp = Repo.get_by(EventRsvp, event_id: event.id, guest_identity_id: identity.id)
      {:ok, %{event: event, identity: identity, rsvp: rsvp}}
    else
      _invalid_or_gone -> {:error, :invalid}
    end
  end

  @doc """
  Changes a guest's answer through their management link.
  """
  @spec update_guest_rsvp(String.t(), EventRsvp.status()) ::
          {:ok, EventRsvp.t()} | {:error, :invalid}
  def update_guest_rsvp(manage_token, status) when status in [:yes, :no, :maybe] do
    with {:ok, %{event: event, identity: identity}} <- fetch_guest_rsvp(manage_token),
         {:ok, rsvp} <- upsert_guest_rsvp(event, identity, status) do
      {:ok, rsvp}
    else
      _invalid -> {:error, :invalid}
    end
  end

  @doc """
  Erases a guest and everything they created, through their management
  link (SPEC §12).
  """
  @spec erase_guest(String.t()) :: :ok | {:error, :invalid}
  def erase_guest(manage_token) do
    with {:ok, %{identity: identity}} <- fetch_guest_rsvp(manage_token) do
      Guests.erase(identity)
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
    |> Ecto.Changeset.validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/)
    |> Ecto.Changeset.validate_length(:email, max: 160)
    |> Ecto.Changeset.validate_length(:display_name, min: 1, max: 120)
  end

  ## Comments — the same engine as posts (ADR 0007)

  @doc """
  Comments on an event, honoring the group's comment policy and the
  one-reply-level rule.
  """
  @spec create_comment(User.t(), Event.t(), map()) ::
          {:ok, Comment.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_comment(%User{} = author, %Event{} = event, attrs) do
    group = Repo.get!(Group, event.group_id)

    if Authorization.can?(author, :comment_in_group, group) and
         is_nil(event.comment_locked_at) do
      parent_id = normalize_parent(attrs["parent_comment_id"])

      %Comment{}
      |> Comment.create_changeset(%{
        "body_markdown" => attrs["body_markdown"],
        "parent_comment_id" => parent_id,
        "author_user_id" => author.id
      })
      |> Ecto.Changeset.put_change(:event_id, event.id)
      |> Repo.insert()
    else
      {:error, :unauthorized}
    end
  end

  defp normalize_parent(nil), do: nil
  defp normalize_parent(""), do: nil

  defp normalize_parent(parent_comment_id) do
    case Repo.get(Comment, parent_comment_id) do
      nil -> nil
      %Comment{parent_comment_id: nil} = parent -> parent.id
      %Comment{parent_comment_id: grandparent_id} -> grandparent_id
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
             from(event in Event, where: event.group_id == ^group.id, order_by: event.starts_at)
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
    reminder_at = DateTime.add(event.starts_at, -24, :hour)

    if DateTime.compare(reminder_at, DateTime.utc_now()) == :gt do
      %{"event_id" => event.id, "starts_at" => DateTime.to_iso8601(event.starts_at)}
      |> Kammer.Workers.EventReminderWorker.new(scheduled_at: reminder_at)
      |> Oban.insert()
    end

    :ok
  end
end
