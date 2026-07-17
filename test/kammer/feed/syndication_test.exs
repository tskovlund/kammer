defmodule Kammer.Feed.SyndicationTest do
  @moduledoc """
  RSS/Atom generation for public group feeds (SPEC §8) — pure XML
  shape and escaping, no database.
  """

  use ExUnit.Case, async: true

  alias Kammer.Feed.Post
  alias Kammer.Feed.Syndication

  defp post(attrs) do
    struct(
      %Post{
        id: "11111111-1111-1111-1111-111111111111",
        published_at: ~U[2026-07-01 12:00:00Z],
        inserted_at: ~U[2026-07-01 12:00:00Z]
      },
      attrs
    )
  end

  # A stand-in for the caller's `unverified_url`-backed resolver
  # (`KammerWeb.GroupFeedController`) — pins the per-item link shape
  # (issue #341) without depending on the web layer.
  defp post_link_fun(post), do: "https://kammer.test/c/tk/g/choir/p/#{post.id}"

  describe "rss/1" do
    test "produces a well-formed channel with one item per post" do
      xml =
        Syndication.rss(%{
          title: "Choir",
          description: "The choir group",
          link: "https://kammer.test/c/tk/g/choir",
          feed_url: "https://kammer.test/c/tk/g/choir/feed.rss",
          posts: [post(body_markdown: "Rehearsal moved to **Thursday**.")],
          post_link_fun: &post_link_fun/1
        })

      assert xml =~ ~s(<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">)
      assert xml =~ "<title>Choir</title>"
      # Feed-level link stays the group page.
      assert xml =~ "<link>https://kammer.test/c/tk/g/choir</link>"

      assert xml =~
               ~s(<atom:link href="https://kammer.test/c/tk/g/choir/feed.rss" rel="self" type="application/rss+xml"/>)

      assert xml =~ "<title>Rehearsal moved to **Thursday**.</title>"

      # Item-level link is the post's own public page (issue #341), not
      # the group page above.
      assert xml =~
               "<link>https://kammer.test/c/tk/g/choir/p/11111111-1111-1111-1111-111111111111</link>"

      assert xml =~ ~s(<guid isPermaLink="false">11111111-1111-1111-1111-111111111111</guid>)
      assert xml =~ "<pubDate>Wed, 01 Jul 2026 12:00:00 GMT</pubDate>"
      assert xml =~ "<description><![CDATA[<p>Rehearsal moved to <strong>Thursday</strong>.</p>"
    end

    test "escapes XML-significant characters in text fields" do
      xml =
        Syndication.rss(%{
          title: "R&D <Group>",
          description: "desc",
          link: "https://kammer.test/g",
          feed_url: "https://kammer.test/g/feed.rss",
          posts: [],
          post_link_fun: &post_link_fun/1
        })

      assert xml =~ "<title>R&amp;D &lt;Group&gt;</title>"
      refute xml =~ "<Group>"
    end

    test "no posts still produces a valid, empty channel" do
      xml =
        Syndication.rss(%{
          title: "Empty",
          description: "d",
          link: "https://kammer.test/g",
          feed_url: "https://kammer.test/g/feed.rss",
          posts: [],
          post_link_fun: &post_link_fun/1
        })

      refute xml =~ "<item>"
      assert xml =~ "</channel>"
    end
  end

  describe "atom/1" do
    test "produces a well-formed feed with one entry per post" do
      xml =
        Syndication.atom(%{
          title: "Choir",
          link: "https://kammer.test/c/tk/g/choir",
          feed_url: "https://kammer.test/c/tk/g/choir/feed.atom",
          posts: [post(body_markdown: "Hello world")],
          post_link_fun: &post_link_fun/1
        })

      assert xml =~ ~s(<feed xmlns="http://www.w3.org/2005/Atom">)
      assert xml =~ ~s(<link href="https://kammer.test/c/tk/g/choir/feed.atom" rel="self"/>)
      # Feed-level link stays the group page; the entry's own link
      # (below) is the post's public page (issue #341).
      assert xml =~ ~s(<link href="https://kammer.test/c/tk/g/choir"/>)

      assert xml =~
               ~s(<link href="https://kammer.test/c/tk/g/choir/p/11111111-1111-1111-1111-111111111111"/>)

      assert xml =~ "<id>urn:uuid:11111111-1111-1111-1111-111111111111</id>"
      # RFC 4287: for type="html", entities represent characters, not
      # markup — the HTML is escaped text, not literal child elements.
      assert xml =~ ~s(<content type="html">&lt;p&gt;Hello world&lt;/p&gt;)
      assert xml =~ "<updated>2026-07-01T12:00:00Z</updated>"
    end
  end
end
