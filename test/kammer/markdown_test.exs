defmodule Kammer.MarkdownTest do
  @moduledoc """
  Markdown rendering (SPEC §5, §11): the one rendering configuration
  shared by posts, comments, and event descriptions. The sanitization
  boundary — raw HTML and script-bearing links never reach the page —
  is the security-relevant part, since every post/comment/event body
  in the product flows through `to_html/1` unescaped by callers.
  """

  use ExUnit.Case, async: true

  alias Kammer.Markdown

  describe "nil and blank input" do
    test "nil and the empty string render to an empty string" do
      assert Markdown.to_html(nil) == ""
      assert Markdown.to_html("") == ""
    end
  end

  describe "basic Markdown rendering" do
    test "paragraphs, emphasis, and inline code" do
      html = Markdown.to_html("Hello *world*, `code`, and **bold**.")

      assert html =~ "<em>world</em>"
      assert html =~ "<code>code</code>"
      assert html =~ "<strong>bold</strong>"
    end

    test "blank-line-separated text becomes separate paragraphs" do
      html = Markdown.to_html("first\n\nsecond")

      assert html =~ "<p>first</p>"
      assert html =~ "<p>second</p>"
    end
  end

  describe "enabled extensions" do
    test "strikethrough" do
      assert Markdown.to_html("~~gone~~") =~ "<del>gone</del>"
    end

    test "autolinked bare URLs" do
      html = Markdown.to_html("see https://example.com for more")
      assert html =~ ~s(<a href="https://example.com">https://example.com</a>)
    end

    test "GitHub-style tables" do
      html = Markdown.to_html("| a | b |\n|---|---|\n| 1 | 2 |")

      assert html =~ "<table>"
      assert html =~ "<th>a</th>"
      assert html =~ "<td>1</td>"
    end

    test "task lists render as disabled checkboxes" do
      html = Markdown.to_html("- [ ] todo\n- [x] done")

      assert html =~ ~s(type="checkbox" disabled)
      assert html =~ ~s(checked)
    end
  end

  describe "sanitization boundary (SPEC §11) — raw HTML never reaches the page" do
    test "a script tag is omitted, not rendered" do
      html = Markdown.to_html("<script>alert(document.cookie)</script>")

      refute html =~ "<script"
      assert html =~ "raw HTML omitted"
    end

    test "an inline event-handler attribute is omitted" do
      html = Markdown.to_html("<img src=\"x\" onerror=\"alert(1)\">")

      refute html =~ "onerror"
      refute html =~ "<img"
    end

    test "raw HTML mixed with plain text keeps the text but drops the tags" do
      html = Markdown.to_html("<b>bold html</b> normal text")

      refute html =~ "<b>"
      assert html =~ "bold html"
      assert html =~ "normal text"
    end

    test "a javascript: link target is neutralized" do
      html = Markdown.to_html("[click me](javascript:alert(1))")

      refute html =~ "javascript:"
      assert html =~ ">click me</a>"
    end
  end

  describe "unusual characters" do
    test "raw angle brackets and ampersands outside a tag are escaped, not dropped" do
      html = Markdown.to_html("plain text with <not-a-real-tag & an ampersand")

      refute html =~ "<not-a-real-tag"
      assert html =~ "&lt;not-a-real-tag"
      assert html =~ "&amp;"
    end

    test "invalid UTF-8 input falls back to a safe escape rather than raising" do
      # MDEx.to_html/2 errors on invalid UTF-8; the fallback still must
      # not raise or pass the raw bytes through as markup.
      assert Markdown.to_html(<<0xFF, 0xFE>>) == <<0xFF, 0xFE>>
    end
  end
end
