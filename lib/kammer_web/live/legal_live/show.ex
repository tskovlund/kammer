defmodule KammerWeb.LegalLive.Show do
  @moduledoc """
  Public legal page (SPEC §13): privacy policy or imprint. Shows the
  operator's text, or the built-in template until one is published.
  Instance operators get an edit link.
  """

  use KammerWeb, :live_view

  alias Kammer.Authorization
  alias Kammer.Legal

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {Legal.title(@page.key)}
        <:actions :if={@operator?}>
          <.link
            navigate={~p"/legal/#{@page.key}/edit"}
            id="edit-legal-page-link"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-pencil-square" class="size-4" /> {gettext("Edit")}
          </.link>
        </:actions>
      </.header>

      <article id="legal-page-content" class="prose prose-sm max-w-none dark:prose-invert">
        {Phoenix.HTML.raw(Kammer.Markdown.to_html(@page.content_markdown))}
      </article>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"key" => key}, _session, socket) do
    if Legal.valid_key?(key) do
      operator? = Authorization.instance_operator?(socket.assigns.current_scope)

      {:ok,
       socket
       |> assign(:page, Legal.get_page(key))
       |> assign(:page_title, Legal.title(key))
       |> assign(:operator?, operator?)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Page not found"))
       |> push_navigate(to: ~p"/")}
    end
  end
end
