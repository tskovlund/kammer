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
  """

  alias Kammer.Feed.Post
  alias Kammer.Markdown

  @title_length 80

  @doc """
  An RSS 2.0 `<rss>` document listing `posts`, newest first.
  """
  @spec rss(map()) :: String.t()
  def rss(%{title: title, description: description, link: link, feed_url: feed_url, posts: posts}) do
    items = Enum.map_join(posts, "", &rss_item(&1, link))

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
  def atom(%{title: title, link: link, feed_url: feed_url, posts: posts}) do
    entries = Enum.map_join(posts, "", &atom_entry(&1, link))
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

  defp rss_item(%Post{} = post, group_link) do
    """
    <item>
    <title>#{escape(title_for(post))}</title>
    <link>#{escape(group_link)}</link>
    <guid isPermaLink="false">#{post.id}</guid>
    <pubDate>#{rfc822(post_updated_at(post))}</pubDate>
    <description>#{cdata(Markdown.to_html(post.body_markdown))}</description>
    </item>
    """
  end

  defp atom_entry(%Post{} = post, group_link) do
    """
    <entry>
    <title>#{escape(title_for(post))}</title>
    <link href="#{escape(group_link)}"/>
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

  defp escape(nil), do: ""

  defp escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  # CDATA content only needs protecting against an embedded "]]>"
  # sequence, which would otherwise close the section early.
  defp cdata(html) do
    "<![CDATA[" <> String.replace(html, "]]>", "]]]]><![CDATA[>") <> "]]>"
  end
end
