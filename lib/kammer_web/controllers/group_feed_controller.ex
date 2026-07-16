defmodule KammerWeb.GroupFeedController do
  @moduledoc """
  RSS/Atom syndication for public groups (SPEC §8). No secret token —
  gated by the exact same `Authorization.authorize(nil, :view_group,
  group)` check anonymous visitors already pass to view the group
  page (`Groups.fetch_viewable_group/3`), so private and
  community-only groups 404 like any other content an anonymous
  visitor can't see.

  The `<link>` back to the group page is an `unverified_url/2`: since
  the LiveView removal (#187) `/c/:slug/g/:slug` is a PWA client-side
  route served by the catch-all, not a compile-verifiable server route.
  The `feed_url` self-links stay `~p` — those *are* this controller's
  own routes.
  """

  use KammerWeb, :controller

  alias Kammer.Communities
  alias Kammer.Feed
  alias Kammer.Feed.Post
  alias Kammer.Feed.Syndication
  alias Kammer.Groups

  @post_limit 20

  @doc "RSS 2.0 feed of a public group's recent posts."
  @spec rss(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rss(conn, params) do
    with {:ok, community, group, posts} <- fetch(params) do
      body =
        Syndication.rss(%{
          title: group.name,
          description: group.description || group.name,
          link: unverified_url(conn, "/c/#{community.slug}/g/#{group.slug}"),
          feed_url: url(~p"/c/#{community.slug}/g/#{group.slug}/feed.rss"),
          posts: posts
        })

      conn |> put_resp_content_type("application/rss+xml") |> send_resp(200, body)
    else
      _error -> send_resp(conn, 404, "Not found")
    end
  end

  @doc "Atom 1.0 feed of a public group's recent posts."
  @spec atom(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def atom(conn, params) do
    with {:ok, community, group, posts} <- fetch(params) do
      body =
        Syndication.atom(%{
          title: group.name,
          link: unverified_url(conn, "/c/#{community.slug}/g/#{group.slug}"),
          feed_url: url(~p"/c/#{community.slug}/g/#{group.slug}/feed.atom"),
          posts: posts
        })

      conn |> put_resp_content_type("application/atom+xml") |> send_resp(200, body)
    else
      _error -> send_resp(conn, 404, "Not found")
    end
  end

  defp fetch(%{"community_slug" => community_slug, "group_slug" => group_slug}) do
    with %Communities.Community{} = community <-
           Communities.get_community_by_slug(community_slug),
         {:ok, group} <- Groups.fetch_viewable_group(nil, community, group_slug) do
      {posts, _next_cursor} = Feed.list_group_feed_page(nil, group, nil, @post_limit)
      {:ok, community, group, Enum.reject(posts, &Post.deleted?/1)}
    end
  end
end
