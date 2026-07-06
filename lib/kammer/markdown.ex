defmodule Kammer.Markdown do
  @moduledoc """
  Markdown rendering (SPEC §5: Markdown canonical; SPEC §11: sanitized
  output). One rendering configuration for the whole product — posts,
  comments, event descriptions — via MDEx with raw HTML disabled.
  """

  @render_options [
    extension: [
      table: true,
      strikethrough: true,
      autolink: true,
      tasklist: true
    ],
    render: [unsafe: false, escape: false]
  ]

  @doc """
  Renders Markdown to sanitized HTML. Raw HTML in the source is omitted.
  """
  @spec to_html(String.t() | nil) :: String.t()
  def to_html(nil), do: ""

  def to_html(markdown) when is_binary(markdown) do
    case MDEx.to_html(markdown, @render_options) do
      {:ok, html} -> html
      {:error, _reason} -> Phoenix.HTML.html_escape(markdown) |> Phoenix.HTML.safe_to_string()
    end
  end
end
