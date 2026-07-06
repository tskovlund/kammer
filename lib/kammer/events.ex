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
              rsvps: [:user],
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
    with :ok <- Authorization.authorize(creator, :post_in_group, group) do
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
        {group,
         Repo.all(
           from(event in Event, where: event.group_id == ^group.id, order_by: event.starts_at)
         )}
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
             where: membership.user_id == ^user.id,
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
