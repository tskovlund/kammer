defmodule KammerWeb.GroupFeedController do
  @moduledoc """
  RSS/Atom syndication for public groups (SPEC §8). No secret token —
  gated by `Authorization.publicly_readable?/1`, the one shared
  public line (issue #345): private and community-only groups 404
  like any other content an anonymous visitor can't see, and so do
  archived and sealed public groups — a feed whose every item links
  into pages the public API refuses to serve would be all dead ends.

  The `<link>` back to the group page is an `unverified_url/2`: since
  the LiveView removal (#187) `/c/:slug/g/:slug` is a PWA client-side
  route served by the catch-all, not a compile-verifiable server route.
  The `feed_url` self-links stay `~p` — those *are* this controller's
  own routes. Each item's own link points at that post's public page
  under the same group path (`/p/:post_id`, #246) — also
  `unverified_url/2`, for the same reason (issue #341: items used to
  carry the group link instead, a leftover from #54 shipping feeds
  before #246 gave posts a page of their own).
  """

  use KammerWeb, :controller

  alias Kammer.Authorization
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
      group_path = "/c/#{community.slug}/g/#{group.slug}"

      body =
        Syndication.rss(%{
          title: group.name,
          description: group.description || group.name,
          link: unverified_url(conn, group_path),
          feed_url: url(~p"/c/#{community.slug}/g/#{group.slug}/feed.rss"),
          posts: posts,
          post_link_fun: &unverified_url(conn, group_path <> "/p/#{&1.id}")
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
      group_path = "/c/#{community.slug}/g/#{group.slug}"

      body =
        Syndication.atom(%{
          title: group.name,
          link: unverified_url(conn, group_path),
          feed_url: url(~p"/c/#{community.slug}/g/#{group.slug}/feed.atom"),
          posts: posts,
          post_link_fun: &unverified_url(conn, group_path <> "/p/#{&1.id}")
        })

      conn |> put_resp_content_type("application/atom+xml") |> send_resp(200, body)
    else
      _error -> send_resp(conn, 404, "Not found")
    end
  end

  defp fetch(%{"community_slug" => community_slug, "group_slug" => group_slug}) do
    with %Communities.Community{} = community <-
           Communities.get_community_by_slug(community_slug),
         {:ok, group} <- Groups.fetch_viewable_group(nil, community, group_slug),
         true <- Authorization.publicly_readable?(group) do
      {posts, _next_cursor} = Feed.list_group_feed_page(nil, group, nil, @post_limit)
      {:ok, community, group, Enum.reject(posts, &Post.deleted?/1)}
    end
  end
end
