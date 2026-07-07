defmodule KammerWeb.LegalLive.Edit do
  @moduledoc """
  Operator editor for a legal page (SPEC §13). Prefilled with the
  built-in template until the operator publishes their own text.
  """

  use KammerWeb, :live_view

  alias Kammer.Authorization
  alias Kammer.Legal

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {gettext("Edit %{page}", page: Legal.title(@page.key))}
        <:subtitle>
          {gettext("Published at /legal/%{key} — Markdown supported.", key: @page.key)}
        </:subtitle>
      </.header>

      <.form for={@form} id="legal-page-form" phx-submit="save" class="space-y-4">
        <.input
          field={@form[:content_markdown]}
          type="textarea"
          label={gettext("Content")}
          rows="20"
        />
        <div class="flex items-center justify-between">
          <.link navigate={~p"/legal/#{@page.key}"} class="btn btn-ghost">
            {gettext("Cancel")}
          </.link>
          <.button variant="primary" phx-disable-with={gettext("Saving…")}>
            {gettext("Publish")}
          </.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"key" => key}, _session, socket) do
    user = socket.assigns.current_scope.user

    cond do
      not Legal.valid_key?(key) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Page not found"))
         |> push_navigate(to: ~p"/")}

      not Authorization.instance_operator?(user) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Only instance operators can edit legal pages."))
         |> push_navigate(to: ~p"/legal/#{key}")}

      true ->
        page = Legal.get_page(key)

        {:ok,
         socket
         |> assign(:page, page)
         |> assign(:page_title, Legal.title(key))
         |> assign(:form, to_form(Legal.change_page(page)))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"legal_page" => params}, socket) do
    user = socket.assigns.current_scope.user
    key = socket.assigns.page.key

    case Legal.upsert_page(user, key, params) do
      {:ok, _page} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Published."))
         |> push_navigate(to: ~p"/legal/#{key}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, gettext("Only instance operators can edit legal pages."))}
    end
  end
end
