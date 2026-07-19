defmodule Kammer.Notifications do
  @moduledoc """
  Layered notifications (SPEC §9): in-app center, email, and Web Push,
  with "highlights" defaults — push+email for mentions, replies to you,
  acknowledgment-required posts, and event activity; ordinary posts stay
  in-app + digest. Broadcast groups (admins-only posting)
  default to "everything": announcement groups should announce.

  Per-user, per-group levels: everything / highlights / mentions-only /
  muted. The channel matrix is a pure function (`channels_for/2`) so the
  policy is testable at a glance.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Feed
  alias Kammer.Feed.Comment
  alias Kammer.Feed.Mentions
  alias Kammer.Feed.Post
  alias Kammer.Groups.Group
  alias Kammer.Groups.GroupMembership
  alias Kammer.Notifications.Notification
  alias Kammer.Notifications.NotificationPreference
  alias Kammer.Notifications.PushSubscription
  alias Kammer.Repo

  @type channel() :: :in_app | :push | :email
  @type kind() ::
          :post
          | :mention
          | :reply
          | :acknowledgment_required
          | :event_created
          | :event_reminder
          | :event_promoted

  ## Policy — pure

  @doc """
  The channels a notification of `kind` reaches for a member at `level`
  (SPEC §9 defaults).
  """
  @spec channels_for(kind(), NotificationPreference.level()) :: [channel()]
  def channels_for(_kind, :muted), do: []

  def channels_for(:mention, _level), do: [:in_app, :push, :email]

  def channels_for(_kind, :mentions_only), do: []

  def channels_for(:post, :everything), do: [:in_app, :push, :email]
  def channels_for(:post, :highlights), do: [:in_app]

  def channels_for(kind, level)
      when kind in [
             :reply,
             :acknowledgment_required,
             :event_created,
             :event_reminder,
             :event_promoted
           ] and
             level in [:everything, :highlights],
      do: [:in_app, :push, :email]

  @doc """
  The default level for a group: broadcast groups (admins-only posting)
  default to everything (SPEC §9), all others to highlights.
  """
  @spec default_level(Group.t()) :: NotificationPreference.level()
  def default_level(%Group{posting_policy: :admins_only}), do: :everything
  def default_level(%Group{}), do: :highlights

  @doc """
  The member's effective level for a group: their preference, or the
  group default.
  """
  @spec effective_level(User.t(), Group.t()) :: NotificationPreference.level()
  def effective_level(%User{} = user, %Group{} = group) do
    case Repo.get_by(NotificationPreference, user_id: user.id, group_id: group.id) do
      nil -> default_level(group)
      %NotificationPreference{level: level} -> level
    end
  end

  @doc """
  Sets the member's notification level for a group.
  """
  @spec set_level(User.t(), Group.t(), NotificationPreference.level()) ::
          {:ok, NotificationPreference.t()} | {:error, Ecto.Changeset.t()}
  def set_level(%User{} = user, %Group{} = group, level) do
    %NotificationPreference{}
    |> NotificationPreference.changeset(%{user_id: user.id, group_id: group.id, level: level})
    |> Repo.insert(
      on_conflict: [set: [level: level, updated_at: DateTime.utc_now(:second)]],
      conflict_target: [:user_id, :group_id],
      returning: true
    )
  end

  ## PubSub

  @doc "PubSub topic for a user's notifications."
  @spec user_topic(User.t() | Ecto.UUID.t()) :: String.t()
  def user_topic(%User{id: user_id}), do: "notifications:user:#{user_id}"
  def user_topic(user_id) when is_binary(user_id), do: "notifications:user:#{user_id}"

  @doc "Subscribes the caller to the user's notification events."
  @spec subscribe(User.t()) :: :ok | {:error, term()}
  def subscribe(%User{} = user) do
    Phoenix.PubSub.subscribe(Kammer.PubSub, user_topic(user))
  end

  @doc """
  The one insert path for in-app notifications: inserts the row and
  broadcasts it on the owner's topic, so realtime subscribers never
  miss one. Anything creating a `%Notification{}` goes through here —
  a bare `Repo.insert!` would silently skip the broadcast (that's how
  event reminders were invisible to Channels clients until fetched).
  """
  @spec insert_notification!(map()) :: Notification.t()
  def insert_notification!(attrs) when is_map(attrs) do
    notification = Repo.insert!(struct!(Notification, attrs))

    Phoenix.PubSub.broadcast(
      Kammer.PubSub,
      user_topic(notification.user_id),
      {__MODULE__, {:notification_created, notification.id}}
    )

    notification
  end

  ## In-app center

  @doc """
  The user's notifications, newest first.
  """
  @spec list_notifications(User.t(), pos_integer()) :: [Notification.t()]
  def list_notifications(%User{} = user, limit \\ 50) do
    Repo.all(
      from(notification in Notification,
        where: notification.user_id == ^user.id,
        order_by: [desc: notification.inserted_at],
        limit: ^limit,
        preload: [:actor_user, :group, :post, :event]
      )
    )
  end

  @doc """
  One page of the user's notifications, newest first, with the
  associations the API serializer shapes (actor, community, group, and
  the post — so group-authored posts render the group as actor, #167).
  Returns `{notifications, next_cursor}` — `next_cursor` is `nil` on the
  last page (same contract as `Kammer.Feed.list_group_feed_page/4`).
  """
  @spec list_notifications_page(
          User.t(),
          {DateTime.t(), Ecto.UUID.t()} | nil,
          pos_integer()
        ) :: {[Notification.t()], {DateTime.t(), Ecto.UUID.t()} | nil}
  def list_notifications_page(%User{} = user, cursor, limit)
      when limit > 0 and limit <= 100 do
    query =
      from(notification in Notification,
        where: notification.user_id == ^user.id,
        order_by: [desc: notification.inserted_at, desc: notification.id],
        limit: ^(limit + 1),
        preload: [:actor_user, :community, :group, :post]
      )

    query =
      case cursor do
        nil ->
          query

        {cursor_at, cursor_id} ->
          from(notification in query,
            where:
              notification.inserted_at < ^cursor_at or
                (notification.inserted_at == ^cursor_at and notification.id < ^cursor_id)
          )
      end

    notifications = Repo.all(query)

    case Enum.split(notifications, limit) do
      {page, []} -> {page, nil}
      {page, _more} -> {page, page |> List.last() |> then(&{&1.inserted_at, &1.id})}
    end
  end

  @doc """
  One notification with the associations the API serializer shapes,
  scoped to the owner — someone else's id reads as `nil`.
  """
  @spec get_notification(User.t(), Ecto.UUID.t()) :: Notification.t() | nil
  def get_notification(%User{} = user, notification_id) do
    case Ecto.UUID.cast(notification_id) do
      {:ok, uuid} ->
        Repo.one(
          from(notification in Notification,
            where: notification.id == ^uuid and notification.user_id == ^user.id,
            preload: [:actor_user, :community, :group, :post]
          )
        )

      :error ->
        nil
    end
  end

  @doc """
  Count of unread notifications.
  """
  @spec unread_count(User.t() | nil) :: non_neg_integer()
  def unread_count(nil), do: 0

  def unread_count(%User{} = user) do
    Repo.aggregate(
      from(notification in Notification,
        where: notification.user_id == ^user.id and is_nil(notification.read_at)
      ),
      :count
    )
  end

  @doc """
  Marks one notification read (scoped to the owner). Someone else's id —
  or one that doesn't exist — reads as `{:error, :not_found}`, the same
  answer for both so ids can't be probed.
  """
  @spec mark_read(User.t(), Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def mark_read(%User{} = user, notification_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(notification_id),
         {count, nil} when count > 0 <-
           Repo.update_all(
             from(notification in Notification,
               where: notification.id == ^uuid and notification.user_id == ^user.id
             ),
             set: [read_at: DateTime.utc_now(:second)]
           ) do
      :ok
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc """
  Marks all of the user's notifications read.
  """
  @spec mark_all_read(User.t()) :: :ok
  def mark_all_read(%User{} = user) do
    Repo.update_all(
      from(notification in Notification,
        where: notification.user_id == ^user.id and is_nil(notification.read_at)
      ),
      set: [read_at: DateTime.utc_now(:second)]
    )

    :ok
  end

  ## Fan-out

  @doc """
  Fans a published post out to group members (minus the author):
  mentions escalate, acknowledgment-required posts are highlights,
  ordinary posts follow the level matrix.
  """
  @spec fanout_post(Post.t()) :: :ok
  def fanout_post(%Post{} = post) do
    group = Repo.get!(Group, post.group_id)
    mentions = Mentions.extract(post.body_markdown)
    memberships = memberships_with_users(group)

    base_kind = if post.acknowledgment_required, do: :acknowledgment_required, else: :post

    Enum.each(memberships, fn membership ->
      recipient = membership.user

      cond do
        recipient.id == post.author_user_id ->
          :ok

        mentioned?(mentions, membership, recipient, post.body_markdown) ->
          deliver(recipient, group, :mention, post: post, actor_id: post.author_user_id)

        true ->
          deliver(recipient, group, base_kind, post: post, actor_id: post.author_user_id)
      end
    end)
  end

  @doc """
  Fans a new comment out: "reply to you" for the subject's author and the
  parent comment author; mentions escalate for everyone mentioned. Covers
  post, event, and assignment comments alike — one engine (ADR 0007).
  """
  @spec fanout_comment(Comment.t()) :: :ok
  def fanout_comment(%Comment{} = comment) do
    {group, subject_author_id, references} = comment_subject(comment)
    mentions = Mentions.extract(comment.body_markdown)

    parent_author_id =
      case comment.parent_comment_id do
        nil ->
          nil

        parent_id ->
          Repo.one(from(c in Comment, where: c.id == ^parent_id, select: c.author_user_id))
      end

    reply_target_ids =
      [subject_author_id, parent_author_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == comment.author_user_id))

    memberships = memberships_with_users(group)

    Enum.each(memberships, fn membership ->
      recipient = membership.user

      cond do
        recipient.id == comment.author_user_id ->
          :ok

        mentioned?(mentions, membership, recipient, comment.body_markdown) ->
          deliver(recipient, group, :mention, [actor_id: comment.author_user_id] ++ references)

        recipient.id in reply_target_ids ->
          deliver(recipient, group, :reply, [actor_id: comment.author_user_id] ++ references)

        true ->
          :ok
      end
    end)
  end

  # The comment's host group, the subject's author (for "reply to you"
  # fan-out), and the reference keys `deliver/4` attaches to the
  # notification. `Feed.comment_context/1` owns the post/event/assignment
  # branching and the group resolution (#124) — this only maps the
  # already-fetched subject to its author and reference key.
  defp comment_subject(%Comment{} = comment) do
    {group, subject} = Feed.comment_context(comment)
    {author_user_id, references} = subject_author_and_references(subject, comment)
    {group, author_user_id, references}
  end

  defp subject_author_and_references(%Post{} = post, comment),
    do: {post.author_user_id, [post: post, comment: comment]}

  defp subject_author_and_references(%Kammer.Events.Event{} = event, comment),
    do: {event.created_by_user_id, [event: event, comment: comment]}

  defp subject_author_and_references(%Kammer.Assignments.Assignment{} = assignment, comment),
    do: {assignment.created_by_user_id, [assignment: assignment, comment: comment]}

  @doc """
  Fans a new event out to group members (highlight class: event activity
  is push+email by default, SPEC §9).
  """
  @spec fanout_event(Kammer.Events.Event.t()) :: :ok
  def fanout_event(%Kammer.Events.Event{} = event) do
    group = Repo.get!(Group, event.group_id)

    group
    |> memberships_with_users()
    |> Enum.each(fn membership ->
      recipient = membership.user

      if recipient.id != event.created_by_user_id do
        deliver(recipient, group, :event_created,
          event: event,
          actor_id: event.created_by_user_id
        )
      end
    end)
  end

  @doc """
  Tells one member their waitlisted RSVP was promoted to attending
  (issue #318) — event-activity highlight class, so push+email at the
  member's level like the other event kinds. One recipient, not a
  fan-out: the promotion itself names exactly who moved up.
  """
  @spec notify_waitlist_promotion(User.t(), Kammer.Events.Event.t()) :: :ok
  def notify_waitlist_promotion(%User{} = user, %Kammer.Events.Event{} = event) do
    group = Repo.get!(Group, event.group_id)
    deliver(user, group, :event_promoted, event: event)
  end

  defp memberships_with_users(%Group{} = group) do
    Repo.all(
      from(membership in GroupMembership,
        where: membership.group_id == ^group.id,
        join: user in assoc(membership, :user),
        preload: [user: user]
      )
    )
  end

  defp mentioned?(mentions, membership, recipient, body_markdown) do
    mentions.everyone or
      (mentions.admins and membership.role in [:owner, :admin]) or
      display_name_mentioned?(body_markdown, recipient.display_name)
  end

  defp display_name_mentioned?(nil, _display_name), do: false

  defp display_name_mentioned?(body_markdown, display_name) do
    String.contains?(body_markdown, "@" <> display_name)
  end

  defp deliver(recipient, group, kind, references) do
    level = effective_level(recipient, group)
    channels = channels_for(kind, level)

    if :in_app in channels do
      insert_notification!(%{
        user_id: recipient.id,
        community_id: group.community_id,
        group_id: group.id,
        actor_user_id: Keyword.get(references, :actor_id),
        kind: kind,
        post_id: get_reference_id(references, :post),
        comment_id: get_reference_id(references, :comment),
        event_id: get_reference_id(references, :event)
      })
    end

    if :email in channels do
      Kammer.Notifications.NotificationEmail.deliver(recipient, group, kind, references)
    end

    if :push in channels do
      send_push(recipient, push_payload(recipient, group, kind, references))
    end

    :ok
  end

  defp get_reference_id(references, key) do
    case Keyword.get(references, key) do
      nil -> nil
      %{id: id} -> id
    end
  end

  ## Web Push (SPEC §1: VAPID)

  @doc """
  Whether Web Push is configured (VAPID keys present).
  """
  @spec push_enabled?() :: boolean()
  def push_enabled? do
    Application.get_env(:web_push_ex, :vapid, [])
    |> Keyword.get(:private_key)
    |> is_binary()
  end

  @doc "The VAPID public key for client-side subscription, or nil."
  @spec vapid_public_key() :: String.t() | nil
  def vapid_public_key do
    Application.get_env(:web_push_ex, :vapid, []) |> Keyword.get(:public_key)
  end

  @doc """
  Registers a browser push subscription for the user. Re-registering an
  endpoint the user already has is a no-op (`ON CONFLICT DO NOTHING`) —
  browsers re-send the same subscription freely. Anything that isn't the
  browser's `PushSubscription.toJSON()` shape reads as
  `{:error, :invalid_subscription}`.
  """
  @spec register_push_subscription(User.t(), map()) ::
          {:ok, PushSubscription.t()} | {:error, Ecto.Changeset.t() | :invalid_subscription}
  def register_push_subscription(%User{} = user, %{
        "endpoint" => endpoint,
        "keys" => %{"p256dh" => p256dh_key, "auth" => auth_key}
      }) do
    %PushSubscription{}
    |> PushSubscription.changeset(%{
      user_id: user.id,
      endpoint: endpoint,
      p256dh_key: p256dh_key,
      auth_key: auth_key
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :endpoint])
  end

  def register_push_subscription(%User{}, _attrs), do: {:error, :invalid_subscription}

  @doc """
  Removes the user's push subscription for an endpoint. Idempotent —
  deleting an endpoint that isn't registered is still `:ok`, mirroring
  how browsers unsubscribe (they only know the endpoint URL).
  """
  @spec delete_push_subscription(User.t(), String.t()) :: :ok
  def delete_push_subscription(%User{} = user, endpoint) when is_binary(endpoint) do
    Repo.delete_all(
      from(subscription in PushSubscription,
        where: subscription.user_id == ^user.id and subscription.endpoint == ^endpoint
      )
    )

    :ok
  end

  @doc """
  Sends a push payload to all of the user's subscriptions; dead
  subscriptions (404/410) are pruned.
  """
  @spec send_push(User.t(), map()) :: :ok
  def send_push(%User{} = user, payload) do
    if push_enabled?() do
      subscriptions = Repo.all(from(s in PushSubscription, where: s.user_id == ^user.id))
      message = Jason.encode!(payload)

      Enum.each(subscriptions, fn subscription ->
        web_push_subscription = %WebPushEx.Subscription{
          endpoint: URI.parse(subscription.endpoint),
          keys: %{p256dh: subscription.p256dh_key, auth: subscription.auth_key}
        }

        request = WebPushEx.request(web_push_subscription, message)

        case Req.post(URI.to_string(request.endpoint),
               headers: Map.to_list(request.headers),
               body: request.body,
               retry: false
             ) do
          {:ok, %Req.Response{status: status}} when status in [404, 410] ->
            Repo.delete(subscription)

          _other ->
            :ok
        end
      end)
    end

    :ok
  end

  defp push_payload(recipient, group, kind, references) do
    Gettext.with_locale(KammerWeb.Gettext, recipient.locale, fn ->
      %{
        title: group.name,
        body: Kammer.Notifications.NotificationEmail.summary_line(kind, references),
        url: Kammer.Notifications.NotificationEmail.target_url(group, references)
      }
    end)
  end
end
