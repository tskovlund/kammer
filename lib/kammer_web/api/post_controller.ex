defmodule KammerWeb.Api.PostController do
  @moduledoc """
  The group feed over the API (RFC 0001): cursor-paginated reads,
  post and comment creation — all through the same context functions
  and authorization the UI uses.
  """

  use KammerWeb, :controller

  alias Kammer.Communities
  alias Kammer.Feed
  alias Kammer.Groups
  alias KammerWeb.Api.Pagination
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_group(conn, slug, group_slug, fn group ->
      {posts, next_cursor} =
        Feed.list_group_feed_page(
          conn.assigns.current_scope.user,
          group,
          Pagination.decode(params["after"]),
          Pagination.limit(params)
        )

      json(conn, %{
        data: Enum.map(posts, &Serializer.post/1),
        next_cursor: Pagination.encode(next_cursor)
      })
    end)
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_group(conn, slug, group_slug, fn group ->
      attrs = Map.take(params, ["body_markdown", "acknowledgment_required", "poll"])

      case Feed.create_post(conn.assigns.current_scope.user, group, attrs) do
        {:ok, post} ->
          post = Feed.get_post!(group, post.id)

          conn
          |> put_status(201)
          |> json(%{data: Serializer.post(post)})

        error ->
          ApiError.from_result(conn, error)
      end
    end)
  end

  @spec create_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_comment(
        conn,
        %{"community_slug" => slug, "group_slug" => group_slug, "post_id" => post_id} = params
      ) do
    with_group(conn, slug, group_slug, fn group ->
      # Cast before querying: a malformed id is a plain 404, not a
      # `Ecto.Query.CastError` 500 (see #155).
      with {:ok, post_id} <- Ecto.UUID.cast(post_id) do
        post = Feed.get_post!(group, post_id)

        attrs = Map.take(params, ["body_markdown", "parent_comment_id"])

        case Feed.create_comment(conn.assigns.current_scope.user, post, attrs) do
          {:ok, comment} ->
            conn
            |> put_status(201)
            |> json(%{data: Serializer.comment(comment)})

          error ->
            ApiError.from_result(conn, error)
        end
      else
        :error -> ApiError.send(conn, :not_found, "Not found.")
      end
    end)
  rescue
    Ecto.NoResultsError -> ApiError.send(conn, :not_found, "Not found.")
  end

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
end
