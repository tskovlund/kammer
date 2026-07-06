defmodule KammerWeb.UserLive.Bookmarks do
  @moduledoc """
  "My other servers" (SPEC §3): per-user cross-instance bookmarks — smart
  links to other Kammer instances the user belongs to. Plain navigation,
  relying on persistent sessions there.
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

  alias Kammer.Communities
  alias Kammer.Communities.InstanceBookmark

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {gettext("My other servers")}
        <:subtitle>
          {gettext("Bookmarks to other Kammer instances you belong to.")}
        </:subtitle>
      </.header>

      <ul :if={@bookmarks != []} class="space-y-2">
        <li
          :for={bookmark <- @bookmarks}
          class="flex items-center gap-3 rounded-box border border-base-200 p-3"
        >
          <.icon name="hero-server" class="size-5 text-base-content/40" />
          <a href={bookmark.url} class="min-w-0 flex-1 hover:underline" rel="noopener">
            <p class="truncate font-medium">{bookmark.name}</p>
            <p class="truncate text-sm text-base-content/50">{bookmark.url}</p>
          </a>
          <.button
            phx-click="delete"
            phx-value-id={bookmark.id}
            data-confirm={gettext("Remove this bookmark?")}
            class="btn btn-ghost btn-xs"
          >
            {gettext("Remove")}
          </.button>
        </li>
      </ul>

      <.empty_state
        :if={@bookmarks == []}
        icon="hero-server"
        headline={gettext("No other servers yet")}
        description={
          gettext("If you belong to communities on other Kammer instances, bookmark them here.")
        }
      />

      <.form for={@form} id="bookmark_form" phx-submit="save" class="pt-4">
        <.input field={@form[:name]} type="text" label={gettext("Name")} required />
        <.input
          field={@form[:url]}
          type="url"
          label={gettext("Address")}
          placeholder="https://kammer.example.org"
          required
        />
        <.button variant="primary">{gettext("Add server")}</.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> load_bookmarks() |> assign_empty_form()}
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"instance_bookmark" => bookmark_params}, socket) do
    current_user = socket.assigns.current_scope.user

    case Communities.create_instance_bookmark(current_user, bookmark_params) do
      {:ok, _bookmark} ->
        {:noreply, socket |> load_bookmarks() |> assign_empty_form()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("delete", %{"id" => bookmark_id}, socket) do
    :ok = Communities.delete_instance_bookmark(socket.assigns.current_scope.user, bookmark_id)
    {:noreply, load_bookmarks(socket)}
  end

  defp load_bookmarks(socket) do
    bookmarks = Communities.list_instance_bookmarks(socket.assigns.current_scope.user)
    assign(socket, :bookmarks, bookmarks)
  end

  defp assign_empty_form(socket) do
    assign(socket, :form, to_form(Communities.change_instance_bookmark(%InstanceBookmark{})))
  end
end
