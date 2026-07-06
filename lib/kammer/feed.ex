defmodule Kammer.Feed do
  @moduledoc """
  The feed (SPEC §5): Markdown posts with images, polls, and file
  attachments; emoji reactions; one-level comments with per-post locks;
  pins; scheduled publishing; acknowledgment-required posts; edit history;
  soft-delete stubs; and live updates over PubSub.

  Strictly chronological plus pinned posts — no ranking, ever (ADR 0006).
  All permission decisions are delegated to `Kammer.Authorization`.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Authorization
  alias Kammer.Communities.Community
  alias Kammer.Feed.Comment
  alias Kammer.Feed.FeedVisit
  alias Kammer.Feed.Mentions
  alias Kammer.Feed.Poll
  alias Kammer.Feed.PollVote
  alias Kammer.Feed.Post
  alias Kammer.Feed.PostAcknowledgment
  alias Kammer.Feed.PostAttachment
  alias Kammer.Feed.PostEdit
  alias Kammer.Feed.Reaction
  alias Kammer.Groups
  alias Kammer.Groups.Group
  alias Kammer.RateLimit
  alias Kammer.Repo

  @preloads [
    :author_user,
    :attachments,
    poll: [options: :votes],
    attachments: :stored_file,
    reactions: [],
    acknowledgments: [],
    comments: [:author_user, reactions: [], replies: [:author_user, reactions: []]]
  ]

  ## PubSub

  @doc "PubSub topic for a group's feed."
  @spec group_topic(Group.t() | Ecto.UUID.t()) :: String.t()
  def group_topic(%Group{id: group_id}), do: "feed:group:#{group_id}"
  def group_topic(group_id) when is_binary(group_id), do: "feed:group:#{group_id}"

  @doc "Subscribes the caller to a group's feed events."
  @spec subscribe(Group.t()) :: :ok | {:error, term()}
  def subscribe(%Group{} = group) do
    Phoenix.PubSub.subscribe(Kammer.PubSub, group_topic(group))
  end

  defp broadcast(%Group{} = group, event) do
    Phoenix.PubSub.broadcast(Kammer.PubSub, group_topic(group), {__MODULE__, event})
  end

  ## Reading

  @doc """
  The group feed: pinned posts first, then strictly chronological
  (newest first). Scheduled posts appear only to their author; pending-
  approval posts only to their author and moderators.
  """
  @spec list_group_feed(User.t() | nil, Group.t()) :: [Post.t()]
  def list_group_feed(actor, %Group{} = group) do
    now = DateTime.utc_now(:second)
    relationship = Authorization.relationship(actor, group)
    moderator? = Authorization.can?(actor, :moderate_group, group, relationship)
    actor_id = actor_id(actor)

    from(post in Post,
      where: post.group_id == ^group.id,
      order_by: [desc_nulls_last: post.pinned_at, desc: post.published_at, desc: post.id],
      preload: ^@preloads
    )
    |> visible_posts(actor_id, moderator?, now)
    |> Repo.all()
  end

  @doc """
  A cursor page of the group feed (RFC 0001): strictly chronological
  (newest first, no pinned reordering — clients render the pinned flag),
  the cursor being `{published_at, id}` of the last seen post. Returns
  `{posts, next_cursor}` with `next_cursor` nil on the last page.
  """
  @spec list_group_feed_page(
          User.t() | nil,
          Group.t(),
          {DateTime.t(), Ecto.UUID.t()} | nil,
          pos_integer()
        ) :: {[Post.t()], {DateTime.t(), Ecto.UUID.t()} | nil}
  def list_group_feed_page(actor, %Group{} = group, cursor, limit)
      when limit > 0 and limit <= 100 do
    now = DateTime.utc_now(:second)
    relationship = Authorization.relationship(actor, group)
    moderator? = Authorization.can?(actor, :moderate_group, group, relationship)
    actor_id = actor_id(actor)

    query =
      from(post in Post,
        where: post.group_id == ^group.id,
        order_by: [desc: post.published_at, desc: post.id],
        limit: ^(limit + 1),
        preload: ^@preloads
      )

    query =
      case cursor do
        nil ->
          query

        {cursor_at, cursor_id} ->
          from(post in query,
            where:
              post.published_at < ^cursor_at or
                (post.published_at == ^cursor_at and post.id < ^cursor_id)
          )
      end

    posts = query |> visible_posts(actor_id, moderator?, now) |> Repo.all()

    case Enum.split(posts, limit) do
      {page, []} -> {page, nil}
      {page, _more} -> {page, page |> List.last() |> then(&{&1.published_at, &1.id})}
    end
  end

  @doc """
  The aggregated home feed for the active community (SPEC §5): posts
  from the groups the user is a member of, strictly chronological.
  """
  @spec list_home_feed(User.t(), Community.t()) :: [Post.t()]
  def list_home_feed(%User{} = user, %Community{} = community) do
    now = DateTime.utc_now(:second)
    member_group_ids = user |> Groups.list_member_groups(community) |> Enum.map(& &1.id)

    Repo.all(
      from(post in Post,
        where: post.group_id in ^member_group_ids,
        where: post.published_at <= ^now,
        where: post.pending_approval == false,
        order_by: [desc: post.published_at, desc: post.id],
        limit: 50,
        preload: ^[:group | @preloads]
      )
    )
  end

  defp visible_posts(query, actor_id, true = _moderator?, _now) do
    # Moderators see pending posts; scheduled posts only if their own.
    where(
      query,
      [post],
      post.published_at <= ^DateTime.utc_now(:second) or post.author_user_id == ^actor_id
    )
  end

  defp visible_posts(query, nil, _moderator?, now) do
    where(query, [post], post.published_at <= ^now and post.pending_approval == false)
  end

  defp visible_posts(query, actor_id, false, now) do
    where(
      query,
      [post],
      (post.published_at <= ^now and post.pending_approval == false) or
        post.author_user_id == ^actor_id
    )
  end

  @doc """
  Fetches a post in a group with details preloaded.
  """
  @spec get_post!(Group.t(), Ecto.UUID.t()) :: Post.t()
  def get_post!(%Group{} = group, post_id) do
    Repo.one!(
      from(post in Post,
        where: post.id == ^post_id and post.group_id == ^group.id,
        preload: ^@preloads
      )
    )
  end

  ## Visits (new-since-last-visit marker)

  @doc """
  Returns the previous visit time for the group feed (or `nil`) and
  records now as the latest visit.
  """
  @spec record_visit(User.t() | nil, Group.t()) :: DateTime.t() | nil
  def record_visit(nil, %Group{}), do: nil

  def record_visit(%User{} = user, %Group{} = group) do
    now = DateTime.utc_now(:second)
    existing_visit = Repo.get_by(FeedVisit, user_id: user.id, group_id: group.id)

    case existing_visit do
      nil ->
        Repo.insert!(%FeedVisit{user_id: user.id, group_id: group.id, last_visited_at: now})
        nil

      %FeedVisit{last_visited_at: previous_visit} = visit ->
        visit |> Ecto.Changeset.change(last_visited_at: now) |> Repo.update!()
        previous_visit
    end
  end

  ## Posts

  @doc """
  Creates a post in a group. Handles: authorization (`:post_in_group`,
  `:post_as_group` for group-identity posts), the approval queue
  (SPEC §3), scheduled publishing (future `published_at`), nested poll
  creation, attachment linking, and `@everyone` gating + rate limiting
  (SPEC §5, §11).
  """
  @spec create_post(User.t(), Group.t(), map()) ::
          {:ok, Post.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :rate_limited}
  def create_post(%User{} = author, %Group{} = group, attrs) do
    relationship = Authorization.relationship(author, group)
    author_type = if attrs["author_type"] == "group", do: :group, else: :user

    required_action = if author_type == :group, do: :post_as_group, else: :post_in_group

    with true <-
           Authorization.can?(author, required_action, group, relationship) || :unauthorized,
         :ok <- check_everyone_mention(author, group, relationship, attrs["body_markdown"]) do
      moderator? = Authorization.can?(author, :moderate_group, group, relationship)

      post_attrs =
        attrs
        |> Map.put("community_id", group.community_id)
        |> Map.put("group_id", group.id)
        |> Map.put("author_user_id", author.id)
        |> Map.put("published_at", attrs["published_at"] || DateTime.utc_now(:second))
        |> Map.put("pending_approval", group.approval_queue and not moderator?)

      Repo.transact(fn ->
        with {:ok, post} <- %Post{} |> Post.create_changeset(post_attrs) |> Repo.insert(),
             {:ok, _poll} <- maybe_create_poll(post, attrs["poll"]),
             :ok <- attach_files(post, attrs["stored_file_ids"] || []) do
          {:ok, post}
        end
      end)
      |> case do
        {:ok, post} ->
          now = DateTime.utc_now(:second)

          if Post.scheduled?(post, now) do
            %{"post_id" => post.id}
            |> Kammer.Workers.PublishScheduledPostWorker.new(scheduled_at: post.published_at)
            |> Oban.insert()
          else
            broadcast(group, {:post_created, post.id})
            enqueue_fanout("post", post.id)
          end

          {:ok, get_post!(group, post.id)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :unauthorized -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_everyone_mention(author, group, relationship, body_markdown) do
    mentions = Mentions.extract(body_markdown)

    cond do
      not mentions.everyone ->
        :ok

      not Authorization.can?(author, :moderate_group, group, relationship) ->
        {:error, :unauthorized}

      true ->
        case RateLimit.hit_everyone_mention(group.id) do
          {:allow, _count} -> :ok
          {:deny, _retry} -> {:error, :rate_limited}
        end
    end
  end

  defp maybe_create_poll(_post, nil), do: {:ok, nil}
  defp maybe_create_poll(_post, poll_attrs) when poll_attrs == %{}, do: {:ok, nil}

  defp maybe_create_poll(post, poll_attrs) do
    %Poll{post_id: post.id}
    |> Poll.create_changeset(poll_attrs)
    |> Repo.insert()
  end

  defp attach_files(post, stored_file_ids) do
    stored_file_ids
    |> Enum.with_index()
    |> Enum.each(fn {stored_file_id, position} ->
      Repo.insert!(%PostAttachment{
        post_id: post.id,
        stored_file_id: stored_file_id,
        position: position
      })
    end)

    :ok
  end

  @doc """
  Edits a post's body, recording the previous version for the
  author/admin-visible history (SPEC §5).
  """
  @spec edit_post(User.t(), Post.t(), map()) ::
          {:ok, Post.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def edit_post(%User{} = actor, %Post{} = post, attrs) do
    group = get_group(post)
    relationship = Authorization.relationship(actor, group)

    if Authorization.can_edit_post?(actor, post, group, relationship) do
      Repo.transact(fn ->
        with {:ok, _edit} <-
               Repo.insert(%PostEdit{
                 post_id: post.id,
                 editor_user_id: actor.id,
                 previous_body_markdown: post.body_markdown
               }),
             {:ok, updated_post} <- post |> Post.edit_changeset(attrs) |> Repo.update() do
          {:ok, updated_post}
        end
      end)
      |> tap_broadcast(group, fn post -> {:post_updated, post.id} end)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Lists a post's edit history for the author and admins.
  """
  @spec list_post_edits(User.t(), Post.t()) :: {:ok, [PostEdit.t()]} | {:error, :unauthorized}
  def list_post_edits(%User{} = actor, %Post{} = post) do
    group = get_group(post)
    relationship = Authorization.relationship(actor, group)

    if Authorization.can_view_edit_history?(actor, post, group, relationship) do
      {:ok,
       Repo.all(
         from(edit in PostEdit,
           where: edit.post_id == ^post.id,
           order_by: [desc: edit.inserted_at],
           preload: [:editor_user]
         )
       )}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Soft-deletes a post (author): leaves a "removed" stub preserving thread
  coherence; content purged after 30 days (SPEC §5).
  """
  @spec soft_delete_post(User.t(), Post.t()) :: {:ok, Post.t()} | {:error, :unauthorized}
  def soft_delete_post(%User{} = actor, %Post{} = post) do
    group = get_group(post)
    relationship = Authorization.relationship(actor, group)

    if Authorization.can_soft_delete_post?(actor, post, group, relationship) do
      post
      |> Ecto.Changeset.change(
        deleted_at: DateTime.utc_now(:second),
        deleted_by_user_id: actor.id
      )
      |> Repo.update()
      |> tap_broadcast(group, fn post -> {:post_updated, post.id} end)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Hard-deletes a post immediately (admins and GDPR erasure, SPEC §5).
  """
  @spec hard_delete_post(User.t(), Post.t()) :: {:ok, Post.t()} | {:error, :unauthorized}
  def hard_delete_post(%User{} = actor, %Post{} = post) do
    group = get_group(post)
    relationship = Authorization.relationship(actor, group)

    if Authorization.can_hard_delete_post?(actor, post, group, relationship) do
      result = Repo.delete(post)
      broadcast(group, {:post_deleted, post.id})
      result
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Pins or unpins a post.
  """
  @spec set_pinned(User.t(), Post.t(), boolean()) :: {:ok, Post.t()} | {:error, :unauthorized}
  def set_pinned(%User{} = actor, %Post{} = post, pinned?) do
    group = get_group(post)
    relationship = Authorization.relationship(actor, group)

    if Authorization.can_pin_post?(actor, post, group, relationship) do
      pinned_at = if pinned?, do: DateTime.utc_now(:second)

      post
      |> Ecto.Changeset.change(pinned_at: pinned_at)
      |> Repo.update()
      |> tap_broadcast(group, fn post -> {:post_updated, post.id} end)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Locks or unlocks comments on a post (author and admins, SPEC §3).
  """
  @spec set_comments_locked(User.t(), Post.t(), boolean()) ::
          {:ok, Post.t()} | {:error, :unauthorized}
  def set_comments_locked(%User{} = actor, %Post{} = post, locked?) do
    group = get_group(post)
    relationship = Authorization.relationship(actor, group)

    if Authorization.can_lock_post_comments?(actor, post, group, relationship) do
      locked_at = if locked?, do: DateTime.utc_now(:second)

      post
      |> Ecto.Changeset.change(comment_locked_at: locked_at)
      |> Repo.update()
      |> tap_broadcast(group, fn post -> {:post_updated, post.id} end)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Approves a pending post from the approval queue (SPEC §3).
  """
  @spec approve_post(User.t(), Post.t()) :: {:ok, Post.t()} | {:error, :unauthorized}
  def approve_post(%User{} = actor, %Post{} = post) do
    group = get_group(post)

    with :ok <- Authorization.authorize(actor, :moderate_group, group) do
      post
      |> Ecto.Changeset.change(pending_approval: false)
      |> Repo.update()
      |> tap_broadcast(group, fn post -> {:post_created, post.id} end)
      |> case do
        {:ok, approved_post} = result ->
          enqueue_fanout("post", approved_post.id)
          result

        error ->
          error
      end
    end
  end

  ## Acknowledgments

  @doc """
  Records the actor's explicit acknowledgment of a post (SPEC §5).
  """
  @spec acknowledge_post(User.t(), Post.t()) ::
          {:ok, PostAcknowledgment.t()} | {:error, term()}
  def acknowledge_post(%User{} = actor, %Post{acknowledgment_required: true} = post) do
    group = get_group(post)
    relationship = Authorization.relationship(actor, group)

    if relationship.group_role != nil do
      %PostAcknowledgment{post_id: post.id, user_id: actor.id}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint([:post_id, :user_id])
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:post_id, :user_id])
      |> tap_broadcast(group, fn _acknowledgment -> {:post_updated, post.id} end)
    else
      {:error, :unauthorized}
    end
  end

  def acknowledge_post(%User{}, %Post{}), do: {:error, :not_acknowledgment_post}

  @doc """
  Who has and hasn't acknowledged — author/admins only (SPEC §5).
  """
  @spec acknowledgment_status(User.t(), Post.t()) ::
          {:ok, %{acknowledged: [User.t()], pending: [User.t()]}} | {:error, :unauthorized}
  def acknowledgment_status(%User{} = actor, %Post{} = post) do
    group = get_group(post)
    relationship = Authorization.relationship(actor, group)

    if Authorization.can_view_acknowledgments?(actor, post, group, relationship) do
      {:ok, members} = Groups.list_members(actor, group)

      acknowledged_ids =
        Repo.all(
          from(acknowledgment in PostAcknowledgment,
            where: acknowledgment.post_id == ^post.id,
            select: acknowledgment.user_id
          )
        )
        |> MapSet.new()

      {acknowledged, pending} =
        members
        |> Enum.map(& &1.user)
        |> Enum.split_with(fn user -> MapSet.member?(acknowledged_ids, user.id) end)

      {:ok, %{acknowledged: acknowledged, pending: pending}}
    else
      {:error, :unauthorized}
    end
  end

  ## Comments

  @doc """
  Creates a comment or a reply (exactly one level, ADR 0007): replying to
  a reply attaches to the parent's top-level comment.
  """
  @spec create_comment(User.t(), Post.t(), map()) ::
          {:ok, Comment.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :comments_locked}
  def create_comment(%User{} = author, %Post{} = post, attrs) do
    group = get_group(post)

    cond do
      not Authorization.can?(author, :comment_in_group, group) ->
        {:error, :unauthorized}

      Post.comments_locked?(post) ->
        {:error, :comments_locked}

      Post.deleted?(post) ->
        {:error, :unauthorized}

      true ->
        parent_id = normalize_parent(attrs["parent_comment_id"])

        %Comment{}
        |> Comment.create_changeset(%{
          "body_markdown" => attrs["body_markdown"],
          "post_id" => post.id,
          "parent_comment_id" => parent_id,
          "author_user_id" => author.id
        })
        |> Repo.insert()
        |> tap_broadcast(group, fn _comment -> {:post_updated, post.id} end)
        |> tap_fanout_comment()
    end
  end

  defp tap_fanout_comment({:ok, comment} = result) do
    enqueue_fanout("comment", comment.id)
    result
  end

  defp tap_fanout_comment(other_result), do: other_result

  defp enqueue_fanout(type, id) do
    %{"type" => type, "id" => id}
    |> Kammer.Workers.NotificationFanoutWorker.new()
    |> Oban.insert()
  end

  # One reply level everywhere: replying to a reply reparents to the top.
  defp normalize_parent(nil), do: nil
  defp normalize_parent(""), do: nil

  defp normalize_parent(parent_comment_id) do
    case Repo.get(Comment, parent_comment_id) do
      nil -> nil
      %Comment{parent_comment_id: nil} = parent -> parent.id
      %Comment{parent_comment_id: grandparent_id} -> grandparent_id
    end
  end

  @doc """
  Soft-deletes a comment (author) or hard-deletes (moderators). Handles
  both post and event comments — one engine (ADR 0007).
  """
  @spec delete_comment(User.t(), Comment.t()) ::
          {:ok, Comment.t()} | {:error, :unauthorized}
  def delete_comment(%User{} = actor, %Comment{} = comment) do
    {group, broadcast_post_id} = comment_context(comment)
    relationship = Authorization.relationship(actor, group)

    cond do
      Authorization.can?(actor, :moderate_group, group, relationship) and
          comment.author_user_id != actor.id ->
        comment
        |> Repo.delete()
        |> tap_broadcast(group, fn _comment -> {:post_updated, broadcast_post_id} end)

      comment.author_user_id == actor.id and is_nil(comment.deleted_at) ->
        comment
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
        |> Repo.update()
        |> tap_broadcast(group, fn _comment -> {:post_updated, broadcast_post_id} end)

      true ->
        {:error, :unauthorized}
    end
  end

  defp comment_context(%Comment{post_id: post_id}) when is_binary(post_id) do
    post = Repo.get!(Post, post_id)
    {get_group(post), post.id}
  end

  defp comment_context(%Comment{event_id: event_id}) do
    event = Repo.get!(Kammer.Events.Event, event_id)
    {Repo.get!(Group, event.group_id), event_id}
  end

  ## Reactions

  @doc """
  Toggles the actor's emoji reaction on a post or comment.
  """
  @spec toggle_reaction(User.t(), Post.t() | Comment.t(), String.t()) ::
          {:ok, :added | :removed} | {:error, term()}
  def toggle_reaction(%User{} = actor, subject, emoji) do
    {post, subject_field} =
      case subject do
        %Post{} = post -> {post, :post_id}
        %Comment{} = comment -> {Repo.get!(Post, comment.post_id), :comment_id}
      end

    group = get_group(post)
    relationship = Authorization.relationship(actor, group)

    if Authorization.can_react?(actor, group, relationship) do
      existing_reaction =
        Repo.get_by(Reaction, [
          {subject_field, subject.id},
          {:user_id, actor.id},
          {:emoji, emoji}
        ])

      result =
        case existing_reaction do
          nil ->
            %Reaction{}
            |> Reaction.changeset(%{
              Atom.to_string(subject_field) => subject.id,
              "user_id" => actor.id,
              "emoji" => emoji
            })
            |> Repo.insert()
            |> case do
              {:ok, _reaction} -> {:ok, :added}
              {:error, changeset} -> {:error, changeset}
            end

          %Reaction{} = reaction ->
            Repo.delete(reaction)
            {:ok, :removed}
        end

      broadcast(group, {:post_updated, post.id})
      result
    else
      {:error, :unauthorized}
    end
  end

  ## Polls

  @doc """
  Casts the actor's vote(s). Single-choice polls replace the previous
  vote; multiple-choice polls toggle each selected option.
  """
  @spec vote(User.t(), Poll.t(), [Ecto.UUID.t()]) :: :ok | {:error, term()}
  def vote(%User{} = actor, %Poll{} = poll, option_ids) when is_list(option_ids) do
    post = Repo.get!(Post, poll.post_id)
    group = get_group(post)
    relationship = Authorization.relationship(actor, group)

    cond do
      not Authorization.can_react?(actor, group, relationship) ->
        {:error, :unauthorized}

      Poll.closed?(poll, DateTime.utc_now(:second)) ->
        {:error, :poll_closed}

      true ->
        valid_option_ids =
          Repo.all(
            from(option in Kammer.Feed.PollOption,
              where: option.poll_id == ^poll.id,
              select: option.id
            )
          )

        chosen = option_ids |> Enum.filter(&(&1 in valid_option_ids)) |> Enum.uniq()
        chosen = if poll.multiple_choice, do: chosen, else: Enum.take(chosen, 1)

        Repo.transact(fn ->
          Repo.delete_all(
            from(vote in PollVote,
              where: vote.poll_id == ^poll.id and vote.user_id == ^actor.id
            )
          )

          Enum.each(chosen, fn option_id ->
            Repo.insert!(%PollVote{poll_id: poll.id, option_id: option_id, user_id: actor.id})
          end)

          {:ok, :voted}
        end)

        broadcast(group, {:post_updated, post.id})
        :ok
    end
  end

  ## Purging (Oban-scheduled, SPEC §5: content purged 30 days after soft-delete)

  @doc """
  Purges the content of posts and comments soft-deleted more than 30 days
  ago. The stub rows remain for thread coherence.
  """
  @spec purge_old_deleted_content() :: non_neg_integer()
  def purge_old_deleted_content do
    cutoff = DateTime.add(DateTime.utc_now(:second), -30, :day)

    {purged_posts, _} =
      Repo.update_all(
        from(post in Post,
          where: post.deleted_at <= ^cutoff and is_nil(post.purged_at)
        ),
        set: [body_markdown: "", purged_at: DateTime.utc_now(:second)]
      )

    {purged_comments, _} =
      Repo.update_all(
        from(comment in Comment,
          where: comment.deleted_at <= ^cutoff and is_nil(comment.purged_at)
        ),
        set: [body_markdown: "", purged_at: DateTime.utc_now(:second)]
      )

    purged_posts + purged_comments
  end

  ## Helpers

  defp get_group(%Post{} = post) do
    Repo.get!(Group, post.group_id)
  end

  defp actor_id(nil), do: nil
  defp actor_id(%User{id: user_id}), do: user_id

  defp tap_broadcast({:ok, value} = result, group, event_fun) do
    broadcast(group, event_fun.(value))
    result
  end

  defp tap_broadcast(other_result, _group, _event_fun), do: other_result
end
