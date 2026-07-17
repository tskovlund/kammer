defmodule KammerWeb.GroupFeedController do
  @moduledoc """
  RSS/Atom syndication for public groups (SPEC §8). No secret token —
  gated by `Authorization.publicly_readable?/1`, the one shared
  public line (issue #345): private and community-only groups 404
  like any other content an anonymous visitor can't see, and so do
  archived and sealed public groups — a feed whose every item links
  into pages the public API refuses to serve would be all dead ends.

  The `<link>` targets are PWA client-side routes served by the
  catch-all since the LiveView removal (#187), not compile-verifiable
  server routes — so they build through `KammerWeb.Api.PublicLinks`,
  the same builder the newsletter emails use: one place owns the
  public page shapes, so feed links can't drift from email links.
  Each item's own link is its post's public page (`/p/:post_id`,
  #246; issue #341 — items used to carry the group link instead, a
  leftover from #54 shipping feeds before #246 gave posts a page of
  their own). The `feed_url` self-links stay `~p` — those *are* this
  controller's own routes.
  """

  use KammerWeb, :controller

  alias Kammer.Communities
  alias Kammer.Feed
  alias Kammer.Feed.Post
  alias Kammer.Feed.Syndication
  alias Kammer.Groups
  alias KammerWeb.Api.PublicLinks

  @post_limit 20

  @doc "RSS 2.0 feed of a public group's recent posts."
  @spec rss(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rss(conn, params) do
    with {:ok, community, group, posts} <- fetch(params) do
      body =
        Syndication.rss(%{
          title: group.name,
          description: group.description || group.name,
          link: PublicLinks.absolute_url(PublicLinks.community_group_path(community, group)),
          feed_url: url(~p"/c/#{community.slug}/g/#{group.slug}/feed.rss"),
          posts: posts,
          post_link_fun: &PublicLinks.absolute_url(PublicLinks.post_path(community, group, &1))
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
          link: PublicLinks.absolute_url(PublicLinks.community_group_path(community, group)),
          feed_url: url(~p"/c/#{community.slug}/g/#{group.slug}/feed.atom"),
          posts: posts,
          post_link_fun: &PublicLinks.absolute_url(PublicLinks.post_path(community, group, &1))
        })

      conn |> put_resp_content_type("application/atom+xml") |> send_resp(200, body)
    else
      _error -> send_resp(conn, 404, "Not found")
    end
  end

  defp fetch(%{"community_slug" => community_slug, "group_slug" => group_slug}) do
    # Literally the public JSON API's fetch (issue #345): one shared
    # path, so the feed's gate can't drift from the pages its links
    # land on.
    with %Communities.Community{} = community <-
           Communities.get_community_by_slug(community_slug),
         {:ok, group} <- Groups.fetch_public_group(community, group_slug) do
      {posts, _next_cursor} = Feed.list_group_feed_page(nil, group, nil, @post_limit)
      {:ok, community, group, Enum.reject(posts, &Post.deleted?/1)}
    end
  end
end
