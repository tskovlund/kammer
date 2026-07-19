defmodule Kammer.Feed.Syndication do
  @moduledoc """
  RSS 2.0 and Atom 1.0 generation for public group feeds (SPEC §8:
  "RSS/Atom for every public group feed"). Generated directly, the
  same way `Kammer.Calendar.ICS` builds calendar files — the formats
  are small and stable, and hand-rolling keeps escaping explicit
  rather than pulling in a feed-generation dependency.

  This module knows nothing about the web layer or authorization: the
  caller (a plain controller, gated the same way the group page itself
  is — `Groups.fetch_viewable_group/3`) resolves every URL and passes
  in the posts to render.

  The feed-level `link` is the group page — that's the right target
  for "what is this feed a feed of." Each item's own `<link>` /
  `<link href>` is different: it must point at that one post's public
  page (issue #341; the group-page link every item carried until then
  was correct only until #246 gave posts a page of their own), so the
  caller also passes `post_link_fun`, a `Post.t() -> String.t()`
  resolver, the same "caller hands over a resolved URL" convention
  `KammerWeb.Api.PublicLinks`'s `*_fun` options use.
  """

  alias Kammer.Feed.Post
  alias Kammer.Markdown

  @title_length 80

  @doc """
  An RSS 2.0 `<rss>` document listing `posts`, newest first.
  """
  @spec rss(map()) :: String.t()
  def rss(%{
        title: title,
        description: description,
        link: link,
        feed_url: feed_url,
        posts: posts,
        post_link_fun: post_link_fun
      }) do
    items = Enum.map_join(posts, "", &rss_item(&1, post_link_fun))

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
    <channel>
    <title>#{escape(title)}</title>
    <link>#{escape(link)}</link>
    <description>#{escape(description)}</description>
    <atom:link href="#{escape(feed_url)}" rel="self" type="application/rss+xml"/>
    #{items}</channel>
    </rss>
    """
  end

  @doc """
  An Atom 1.0 `<feed>` document listing `posts`, newest first.
  """
  @spec atom(map()) :: String.t()
  def atom(%{
        title: title,
        link: link,
        feed_url: feed_url,
        posts: posts,
        post_link_fun: post_link_fun
      }) do
    entries = Enum.map_join(posts, "", &atom_entry(&1, post_link_fun))
    updated = posts |> List.first() |> post_updated_at()

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
    <title>#{escape(title)}</title>
    <link href="#{escape(feed_url)}" rel="self"/>
    <link href="#{escape(link)}"/>
    <id>#{escape(link)}</id>
    <updated>#{DateTime.to_iso8601(updated)}</updated>
    #{entries}</feed>
    """
  end

  defp rss_item(%Post{} = post, post_link_fun) do
    """
    <item>
    <title>#{escape(title_for(post))}</title>
    <link>#{escape(post_link_fun.(post))}</link>
    <guid isPermaLink="false">#{post.id}</guid>
    <pubDate>#{rfc822(post_updated_at(post))}</pubDate>
    <description>#{cdata(Markdown.to_html(post.body_markdown))}</description>
    </item>
    """
  end

  defp atom_entry(%Post{} = post, post_link_fun) do
    """
    <entry>
    <title>#{escape(title_for(post))}</title>
    <link href="#{escape(post_link_fun.(post))}"/>
    <id>urn:uuid:#{post.id}</id>
    <updated>#{DateTime.to_iso8601(post_updated_at(post))}</updated>
    <content type="html">#{escape(Markdown.to_html(post.body_markdown))}</content>
    </entry>
    """
  end

  defp post_updated_at(nil), do: DateTime.utc_now(:second)
  defp post_updated_at(%Post{} = post), do: post.published_at || post.inserted_at

  defp title_for(%Post{body_markdown: markdown}) do
    excerpt =
      markdown
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(excerpt) > @title_length do
      String.slice(excerpt, 0, @title_length) <> "…"
    else
      excerpt
    end
  end

  # RFC 822 (RSS pubDate) — English day/month names regardless of
  # locale, since the format itself is fixed English by spec.
  defp rfc822(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")
  end

  # XML 1.0 forbids the C0 control characters other than TAB/LF/CR, plus
  # the U+FFFE/U+FFFF noncharacters. A single one in a user-supplied title
  # or body makes the whole document ill-formed, and a strict parser
  # rejects every item, not just the offending one — one crafted post title
  # takes the feed down for every subscriber (#364). Strip them at the
  # output boundary, the same place the ICS side escapes (#313). (Lone
  # surrogates can't occur here: Elixir strings are UTF-8.)
  @xml_illegal ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x{FFFE}\x{FFFF}]/u

  defp escape(nil), do: ""

  defp escape(text) do
    text
    |> to_string()
    |> String.replace(@xml_illegal, "")
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  # CDATA content is not exempt from XML's character rules, so strip the
  # illegal range here too (this path doesn't run through escape/1), then
  # protect against an embedded "]]>" that would close the section early.
  defp cdata(html) do
    stripped = String.replace(html, @xml_illegal, "")
    "<![CDATA[" <> String.replace(stripped, "]]>", "]]]]><![CDATA[>") <> "]]>"
  end
end
