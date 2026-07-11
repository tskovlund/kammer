defmodule KammerWeb.Api.PostController do
  @moduledoc """
  The group feed over the API (RFC 0001, issue #178): cursor-paginated
  reads plus full write parity — posts (create/edit/delete/pin),
  comments (create/edit/delete), reactions, poll votes,
  acknowledgments, and reporting either to the moderators (issue
  #256) — all through the same context functions and
  authorization the UI uses; the controller adds transport, never
  policy. Writes address posts through `Feed.fetch_visible_post/3`, so
  a post the caller cannot see answers exactly like one that doesn't
  exist (the no-oracle stance of #156).
  """

  use KammerWeb, :controller

  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Feed
  alias Kammer.Groups
  alias Kammer.Moderation
  alias KammerWeb.Api.Pagination
  alias KammerWeb.Api.ReportIntake
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_group(conn, slug, group_slug, fn group ->
      user = conn.assigns.current_scope.user

      {posts, next_cursor} =
        Feed.list_group_feed_page(
          user,
          group,
          Pagination.decode(params["after"]),
          Pagination.limit(params)
        )

      # One relationship lookup for the whole page — every post is in
      # this group, so its `viewer_can` shares the same relationship.
      relationship = Authorization.relationship(user, group)

      json(conn, %{
        data: Enum.map(posts, &Serializer.post(&1, user, relationship)),
        next_cursor: Pagination.encode(next_cursor)
      })
    end)
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_group(conn, slug, group_slug, fn group ->
      user = conn.assigns.current_scope.user

      attrs =
        params
        |> Map.take(["body_markdown", "acknowledgment_required", "poll", "stored_file_ids"])
        |> shape_poll_options()

      case Feed.create_post(user, group, attrs) do
        {:ok, post} ->
          post = Feed.get_post!(group, post.id)
          relationship = Authorization.relationship(user, group)

          conn
          |> put_status(201)
          |> json(%{data: Serializer.post(post, user, relationship)})

        error ->
          ApiError.from_result(conn, error)
      end
    end)
  end

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"post_id" => post_id} = params) do
    with_visible_post(conn, params, post_id, fn group, post, user ->
      with {:ok, _post} <- Feed.edit_post(user, post, Map.take(params, ["body_markdown"])) do
        respond_with_post(conn, user, group, post.id)
      end
    end)
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"post_id" => post_id} = params) do
    # `?hard=true` is the API's spelling of the LiveView's two delete
    # actions: soft (author, tombstone stub) vs. hard (moderator,
    # gone). The contexts authorize each — this only picks which.
    hard? = params["hard"] in [true, "true"]

    with_visible_post(conn, params, post_id, fn group, post, user ->
      result =
        if hard?,
          do: Feed.hard_delete_post(user, post),
          else: Feed.soft_delete_post(user, post)

      with {:ok, deleted_post} <- result do
        # Answer with the feed's tombstone shape either way — a
        # hard-deleted post no longer exists, so its tombstone is
        # built from the struct in hand.
        tombstone = %{post | deleted_at: deleted_post.deleted_at || DateTime.utc_now(:second)}
        relationship = Authorization.relationship(user, group)
        json(conn, %{data: Serializer.post(tombstone, user, relationship)})
      end
    end)
  end

  @spec pin(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def pin(conn, %{"post_id" => post_id} = params),
    do: set_pinned(conn, params, post_id, true)

  @spec unpin(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unpin(conn, %{"post_id" => post_id} = params),
    do: set_pinned(conn, params, post_id, false)

  defp set_pinned(conn, params, post_id, pinned?) do
    with_visible_post(conn, params, post_id, fn group, post, user ->
      with {:ok, _post} <- Feed.set_pinned(user, post, pinned?) do
        respond_with_post(conn, user, group, post.id)
      end
    end)
  end

  @spec react(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def react(conn, %{"post_id" => post_id, "emoji" => emoji} = params) when is_binary(emoji) do
    with_visible_post(conn, params, post_id, fn group, post, user ->
      with {:ok, _change} <- Feed.toggle_reaction(user, post, emoji) do
        respond_with_post(conn, user, group, post.id)
      end
    end)
  end

  def react(conn, _params),
    do: ApiError.send(conn, :bad_request, "Send an `emoji` string.")

  @spec react_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def react_comment(
        conn,
        %{"post_id" => post_id, "comment_id" => comment_id, "emoji" => emoji} = params
      )
      when is_binary(emoji) do
    with_visible_comment(conn, params, post_id, comment_id, fn group, post, comment, user ->
      with {:ok, _change} <- Feed.toggle_reaction(user, comment, emoji) do
        respond_with_comment(conn, user, group, post.id, comment.id)
      end
    end)
  end

  def react_comment(conn, _params),
    do: ApiError.send(conn, :bad_request, "Send an `emoji` string.")

  @spec vote(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def vote(conn, %{"post_id" => post_id, "option_ids" => option_ids} = params)
      when is_list(option_ids) do
    with_visible_post(conn, params, post_id, fn group, post, user ->
      case post.poll do
        nil ->
          ApiError.send(conn, :not_found, "Not found.")

        poll ->
          with :ok <- Feed.vote(user, poll, option_ids),
               {:ok, fresh_post} <- Feed.fetch_visible_post(user, group, post.id) do
            json(conn, %{data: Serializer.poll(fresh_post.poll, user)})
          end
      end
    end)
  end

  def vote(conn, _params),
    do: ApiError.send(conn, :bad_request, "Send `option_ids` as a list (empty to unvote).")

  @spec acknowledge(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def acknowledge(conn, %{"post_id" => post_id} = params) do
    with_visible_post(conn, params, post_id, fn group, post, user ->
      with {:ok, _acknowledgment} <- Feed.acknowledge_post(user, post) do
        respond_with_post(conn, user, group, post.id)
      end
    end)
  end

  @spec acknowledgments(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def acknowledgments(conn, %{"post_id" => post_id} = params) do
    with_visible_post(conn, params, post_id, fn _group, post, user ->
      with {:ok, status} <- Feed.acknowledgment_status(user, post) do
        json(conn, %{
          data: %{
            acknowledged: Enum.map(status.acknowledged, &user_ref/1),
            pending: Enum.map(status.pending, &user_ref/1)
          }
        })
      end
    end)
  end

  @spec create_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_comment(conn, %{"post_id" => post_id} = params) do
    with_group_of(conn, params, fn group ->
      user = conn.assigns.current_scope.user
      attrs = Map.take(params, ["body_markdown", "parent_comment_id"])

      with {:ok, post} <- Feed.fetch_post(group, post_id),
           {:ok, comment} <- Feed.create_comment(user, post, attrs) do
        conn
        |> put_status(201)
        |> json(%{data: Serializer.comment(comment, user)})
      else
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec update_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_comment(conn, %{"post_id" => post_id, "comment_id" => comment_id} = params) do
    with_visible_comment(conn, params, post_id, comment_id, fn group, post, comment, user ->
      with {:ok, _comment} <-
             Feed.edit_comment(user, comment, Map.take(params, ["body_markdown"])) do
        respond_with_comment(conn, user, group, post.id, comment.id)
      end
    end)
  end

  @spec delete_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete_comment(conn, %{"post_id" => post_id, "comment_id" => comment_id} = params) do
    with_visible_comment(conn, params, post_id, comment_id, fn _group, _post, comment, user ->
      with {:ok, deleted_comment} <- Feed.delete_comment(user, comment) do
        # Hard-deleted (moderator) comments no longer exist; answer
        # with the tombstone shape built from the struct in hand.
        tombstone = %{
          comment
          | deleted_at: deleted_comment.deleted_at || DateTime.utc_now(:second)
        }

        json(conn, %{data: Serializer.comment(tombstone, user)})
      end
    end)
  end

  @spec report(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def report(conn, %{"post_id" => post_id, "reason" => reason} = params)
      when is_binary(reason) do
    with_visible_post(conn, params, post_id, fn _group, post, user ->
      ReportIntake.respond(conn, Moderation.report_post(user, post, reason))
    end)
  end

  def report(conn, _params),
    do: ReportIntake.reject_missing_reason(conn)

  @spec report_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def report_comment(
        conn,
        %{"post_id" => post_id, "comment_id" => comment_id, "reason" => reason} = params
      )
      when is_binary(reason) do
    with_visible_comment(conn, params, post_id, comment_id, fn _group, _post, comment, user ->
      ReportIntake.respond(conn, Moderation.report_comment(user, comment, reason))
    end)
  end

  def report_comment(conn, _params),
    do: ReportIntake.reject_missing_reason(conn)

  ## Internals

  defp with_group(conn, community_slug, group_slug, fun) do
    user = conn.assigns.current_scope.user

    with %Communities.Community{} = community <-
           Communities.get_community_by_slug(community_slug),
         {:ok, group} <- Groups.fetch_viewable_group(user, community, group_slug) do
      fun.(group)
    else
      nil -> ApiError.send(conn, :not_found, "Not found.")
      error -> ApiError.from_result(conn, error)
    end
  end

  defp with_group_of(conn, %{"community_slug" => slug, "group_slug" => group_slug}, fun),
    do: with_group(conn, slug, group_slug, fun)

  # The shared head of every post-addressed write: resolve the group,
  # then the post exactly as the caller sees it in the feed — an
  # invisible post (someone else's scheduled or pending one) answers
  # 404 before any permission check could leak that it exists. The
  # callback's error tuples fall through to the one error envelope.
  defp with_visible_post(conn, params, post_id, fun) do
    with_group_of(conn, params, fn group ->
      user = conn.assigns.current_scope.user

      with {:ok, post} <- Feed.fetch_visible_post(user, group, post_id),
           %Plug.Conn{} = responded <- fun.(group, post, user) do
        responded
      else
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  defp with_visible_comment(conn, params, post_id, comment_id, fun) do
    with_visible_post(conn, params, post_id, fn group, post, user ->
      # The visible post's preloaded comments are already filtered the
      # way the feed filters them (pending guest comments only for
      # moderators), so a comment the caller can't see 404s here.
      case find_comment(post, comment_id) do
        nil -> {:error, :not_found}
        comment -> fun.(group, post, comment, user)
      end
    end)
  end

  # Guarded like the event/assignment siblings: a future fetch that skips
  # the comments preload must degrade to the no-oracle 404, not raise.
  defp find_comment(%{comments: comments}, comment_id) when is_list(comments),
    do: Enum.find(comments, &(&1.id == comment_id))

  defp find_comment(_post, _comment_id), do: nil

  defp respond_with_post(conn, user, group, post_id) do
    with {:ok, post} <- Feed.fetch_visible_post(user, group, post_id) do
      relationship = Authorization.relationship(user, group)
      json(conn, %{data: Serializer.post(post, user, relationship)})
    end
  end

  defp respond_with_comment(conn, user, group, post_id, comment_id) do
    with {:ok, post} <- Feed.fetch_visible_post(user, group, post_id),
         %Kammer.Feed.Comment{} = comment <- find_comment(post, comment_id) || :not_found do
      json(conn, %{data: Serializer.comment(comment, user)})
    else
      _gone -> {:error, :not_found}
    end
  end

  defp user_ref(user), do: %{type: "user", id: user.id, display_name: user.display_name}

  # The API takes poll options as a JSON list; positions follow list
  # order (the LiveView composer derives them from its indexed form
  # params the same way). Non-map entries are dropped — the changeset's
  # option-count validation answers for a poll that loses its options.
  defp shape_poll_options(%{"poll" => %{"options" => options} = poll} = attrs)
       when is_list(options) do
    shaped =
      options
      |> Enum.filter(&is_map/1)
      |> Enum.with_index()
      |> Enum.map(fn {option, index} -> Map.put(option, "position", index) end)

    Map.put(attrs, "poll", Map.put(poll, "options", shaped))
  end

  defp shape_poll_options(attrs), do: attrs
end
