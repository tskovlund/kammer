defmodule Kammer.Notifications do
  @moduledoc """
  Layered notifications (SPEC §9): in-app center, email, and Web Push,
  with "highlights" defaults — push+email for mentions, replies to you,
  acknowledgment-required posts, and event activity; ordinary posts stay
  in-app (digests are Phase 2). Broadcast groups (admins-only posting)
  default to "everything": announcement groups should announce.

  Per-user, per-group levels: everything / highlights / mentions-only /
  muted. The channel matrix is a pure function (`channels_for/2`) so the
  policy is testable at a glance.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
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
          :post | :mention | :reply | :acknowledgment_required | :event_created | :event_reminder

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
      when kind in [:reply, :acknowledgment_required, :event_created, :event_reminder] and
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
  Marks one notification read (scoped to the owner).
  """
  @spec mark_read(User.t(), Ecto.UUID.t()) :: :ok
  def mark_read(%User{} = user, notification_id) do
    Repo.update_all(
      from(notification in Notification,
        where: notification.id == ^notification_id and notification.user_id == ^user.id
      ),
      set: [read_at: DateTime.utc_now(:second)]
    )

    :ok
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

  # The comment's host (post, event, or assignment), its author (for
  # "reply to you" fan-out), and the reference keys `deliver/4` attaches
  # to the notification.
  defp comment_subject(%Comment{post_id: post_id} = comment) when is_binary(post_id) do
    post = Repo.get!(Post, post_id)
    {Repo.get!(Group, post.group_id), post.author_user_id, [post: post, comment: comment]}
  end

  defp comment_subject(%Comment{event_id: event_id} = comment) when is_binary(event_id) do
    event = Repo.get!(Kammer.Events.Event, event_id)
    {Repo.get!(Group, event.group_id), event.created_by_user_id, [event: event, comment: comment]}
  end

  defp comment_subject(%Comment{assignment_id: assignment_id} = comment)
       when is_binary(assignment_id) do
    assignment = Repo.get!(Kammer.Assignments.Assignment, assignment_id)
    {Repo.get!(Group, assignment.group_id), assignment.created_by_user_id, [comment: comment]}
  end

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
      Repo.insert!(%Notification{
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
  Registers a browser push subscription for the user.
  """
  @spec register_push_subscription(User.t(), map()) ::
          {:ok, PushSubscription.t()} | {:error, Ecto.Changeset.t()}
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
