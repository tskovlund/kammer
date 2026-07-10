defmodule KammerWeb.Api.PublicController do
  @moduledoc """
  Tokenless public content reads over the API (issue #185 slice B): the
  community/group/event/post surfaces a guest needs to browse before
  filling in the RSVP/signup-claim/comment request forms the
  `GuestController` endpoints already accept — so the PWA can host
  those forms on public content pages without an account (the last
  piece gating the LiveView removal, issue #187).

  Every fetch is scoped through `Kammer.Authorization.publicly_readable?/1`
  (groups) — the same public_link/public_listed-and-not-archived
  boundary the RSS/Atom feeds, `GroupLive.Show`/`EventLive.Show`, and
  the guest request endpoints already expose, hardened here against
  sealed groups since this is a newly-browsable JSON surface (see that
  function's doc). A community/group/event/post that exists but isn't
  publicly readable answers the same neutral 404 a nonexistent one
  gets — no oracle (issue #156/#161) — via `Groups.fetch_public_group/2`
  and `Events.fetch_public_event/2`, the public twins of the
  `fetch_viewable_*` functions the authenticated controllers use.

  A community itself has no separate "public" gate to fail: any
  existing community shows this same public face (name, description,
  its `public_listed` groups) to anonymous browser visitors already
  (`CommunityLive.Home`, `CommunityScope.assign_community`) — this
  only mirrors that over JSON. Its group *listing* stays
  `public_listed`-only (`Groups.list_publicly_readable_groups/1`):
  `public_link` groups are directly reachable by slug below, exactly
  like the RSS feed and `GroupLive.Show`, but per SPEC §3 stay
  unlisted — that's what "unlisted" means.
  """

  use KammerWeb, :controller

  alias Kammer.Communities
  alias Kammer.Communities.Community
  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Feed.Post
  alias Kammer.Groups
  alias KammerWeb.Api.Pagination
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @spec community(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def community(conn, %{"community_slug" => slug}) do
    with_community(conn, slug, fn community ->
      groups = Groups.list_publicly_readable_groups(community)

      json(conn, %{
        data: %{
          community: Serializer.community(community),
          groups: Enum.map(groups, &Serializer.group/1)
        }
      })
    end)
  end

  @spec group(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def group(conn, %{"community_slug" => slug, "group_slug" => group_slug}) do
    with_group(conn, slug, group_slug, fn group ->
      json(conn, %{data: Serializer.group(group)})
    end)
  end

  @spec group_posts(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def group_posts(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_group(conn, slug, group_slug, fn group ->
      {posts, next_cursor} =
        Feed.list_group_feed_page(
          nil,
          group,
          Pagination.decode(params["after"]),
          Pagination.limit(params)
        )

      # Published/non-pending is already enforced at the query
      # (`list_group_feed_page`'s anonymous-actor branch); deleted
      # posts survive that as tombstones for the authenticated feed's
      # UI, but a guest browsing for something to comment on has no
      # use for one, and `Feed.request_guest_comment/4` already refuses
      # to accept a comment on one — dropped here rather than shown as
      # a tombstone, same as `GroupFeedController`'s RSS/Atom filters
      # them for the same reason. `next_cursor` still comes from the
      # unfiltered page, so paging stays stable even when a page's
      # count changes after this filter.
      json(conn, %{
        data: posts |> Enum.reject(&Post.deleted?/1) |> Enum.map(&Serializer.post/1),
        next_cursor: Pagination.encode(next_cursor)
      })
    end)
  end

  @spec post(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def post(conn, %{"community_slug" => slug, "group_slug" => group_slug, "post_id" => post_id}) do
    with_group(conn, slug, group_slug, fn group ->
      case Feed.fetch_visible_post(nil, group, post_id) do
        {:ok, post} ->
          if Post.deleted?(post) do
            ApiError.send(conn, :not_found, "Not found.")
          else
            json(conn, %{data: Serializer.post(post)})
          end

        error ->
          ApiError.from_result(conn, error)
      end
    end)
  end

  @spec event(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def event(conn, %{"community_slug" => slug, "event_id" => event_id}) do
    with_community(conn, slug, fn community ->
      case Events.fetch_public_event(community, event_id) do
        {:ok, event} -> json(conn, %{data: Serializer.event(event)})
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  ## Internals

  defp with_community(conn, slug, fun) do
    case Communities.get_community_by_slug(slug) do
      %Community{} = community -> fun.(community)
      nil -> ApiError.send(conn, :not_found, "Not found.")
    end
  end

  defp with_group(conn, community_slug, group_slug, fun) do
    with_community(conn, community_slug, fn community ->
      case Groups.fetch_public_group(community, group_slug) do
        {:ok, group} -> fun.(group)
        error -> ApiError.from_result(conn, error)
      end
    end)
  end
end
