defmodule KammerWeb.FileLive.Index do
  @moduledoc """
  File space browser (SPEC §7) for both scopes — a group's space or the
  community space: shallow folder tree with breadcrumbs, uploads,
  preset-only folder permissions (ADR 0009), auto-collections ("Images",
  "Posted in feed"), usage with quota bars when the instance runs in
  quota mode, and per-user contribution stats.
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

  alias Kammer.Authorization
  alias Kammer.Files
  alias Kammer.Files.Folder
  alias Kammer.Groups

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_community={@active_community}
      member_communities={@member_communities}
      member_groups={@member_groups}
      community_relationship={@community_relationship}
      unread_notifications={@unread_notifications}
      current_tab={@scope_tab}
    >
      <.header>
        {@space_name}
        <:subtitle>{gettext("Files")}</:subtitle>
      </.header>

      <%!-- Collections + usage --%>
      <div class="flex flex-wrap items-center gap-2">
        <div class="join">
          <button
            :for={{key, label} <- collection_tabs()}
            phx-click="switch_collection"
            phx-value-collection={key}
            class={["btn btn-sm join-item", @collection == key && "btn-primary"]}
          >
            {label}
          </button>
        </div>
        <div class="ml-auto text-sm text-base-content/60">
          {format_bytes(@usage_bytes)}
          <span :if={@quota_bytes}> / {format_bytes(@quota_bytes)}</span>
        </div>
      </div>

      <progress
        :if={@quota_bytes}
        class="progress progress-primary w-full"
        value={@usage_bytes}
        max={@quota_bytes}
      ></progress>

      <%= if @collection == "browse" do %>
        <%!-- Breadcrumbs --%>
        <nav class="flex flex-wrap items-center gap-1 text-sm" aria-label={gettext("Folders")}>
          <button phx-click="open_folder" phx-value-id="" class="link-hover link font-medium">
            {@space_name}
          </button>
          <span :for={folder <- @folder_chain} class="flex items-center gap-1">
            <.icon name="hero-chevron-right" class="size-3.5 text-base-content/40" />
            <button phx-click="open_folder" phx-value-id={folder.id} class="link-hover link">
              {folder.name}
            </button>
          </span>
        </nav>

        <%!-- Folders --%>
        <div :if={@folders != []} class="grid grid-cols-2 gap-2 sm:grid-cols-3">
          <div
            :for={folder <- @folders}
            class="group flex items-center gap-2 rounded-field border border-base-200 px-3 py-2 hover:bg-base-200"
          >
            <button
              phx-click="open_folder"
              phx-value-id={folder.id}
              class="flex min-w-0 flex-1 items-center gap-2 text-left"
            >
              <.icon
                name={
                  if folder.read_override == :admins_only or folder.write_override == :admins_only,
                    do: "hero-lock-closed",
                    else: "hero-folder"
                }
                class="size-5 shrink-0 text-[var(--accent,#3E6B48)]"
              />
              <span class="truncate text-sm font-medium">{folder.name}</span>
            </button>
            <div :if={@can_manage? and folder.system_key == nil} class="dropdown dropdown-end">
              <button
                type="button"
                tabindex="0"
                class="btn btn-ghost btn-xs btn-square opacity-0 group-hover:opacity-100"
              >
                <.icon name="hero-ellipsis-horizontal" class="size-4" />
              </button>
              <ul
                tabindex="0"
                class="dropdown-content menu z-20 w-56 rounded-box border border-base-200 bg-base-100 p-1 text-sm shadow-sm"
              >
                <li>
                  <button phx-click="toggle_read_override" phx-value-id={folder.id}>
                    {if folder.read_override == :admins_only,
                      do: gettext("Read: everyone in scope"),
                      else: gettext("Read: admins only")}
                  </button>
                </li>
                <li>
                  <button phx-click="toggle_write_override" phx-value-id={folder.id}>
                    {if folder.write_override == :admins_only,
                      do: gettext("Write: members"),
                      else: gettext("Write: admins only")}
                  </button>
                </li>
                <li>
                  <button
                    phx-click="delete_folder"
                    phx-value-id={folder.id}
                    data-confirm={gettext("Delete this folder? Files move to the root.")}
                    class="text-error"
                  >
                    {gettext("Delete folder")}
                  </button>
                </li>
              </ul>
            </div>
          </div>
        </div>

        <%!-- New folder + upload --%>
        <div :if={@can_write?} class="flex flex-wrap items-center gap-2">
          <form phx-submit="create_folder" class="flex items-center gap-2">
            <input
              type="text"
              name="name"
              required
              placeholder={gettext("New folder…")}
              class="input input-sm w-44"
            />
            <button type="submit" class="btn btn-ghost btn-sm">
              <.icon name="hero-folder-plus" class="size-4" /> {gettext("Create")}
            </button>
          </form>

          <form phx-submit="upload" phx-change="validate_upload" class="flex items-center gap-2">
            <label class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-up-tray" class="size-4" /> {gettext("Upload")}
              <.live_file_input upload={@uploads.files} class="hidden" />
            </label>
            <button
              :if={@uploads.files.entries != []}
              type="submit"
              class="btn btn-primary btn-sm"
            >
              {gettext("Save %{count} file(s)", count: length(@uploads.files.entries))}
            </button>
          </form>
        </div>

        <div :for={entry <- @uploads.files.entries} class="text-sm text-base-content/60">
          {entry.client_name}
          <progress :if={!entry.done?} value={entry.progress} max="100" class="progress ml-2 w-24"></progress>
        </div>
      <% end %>

      <%!-- Files --%>
      <div :if={@files != []} class="space-y-1">
        <div
          :for={stored_file <- @files}
          class="rounded-field border border-base-200"
        >
          <div class="flex items-center gap-3 px-3 py-2">
            <img
              :if={stored_file.kind == :image}
              src={~p"/files/#{stored_file.id}/thumbnail"}
              alt=""
              loading="lazy"
              class="size-10 rounded object-cover"
            />
            <.icon
              :if={stored_file.kind != :image}
              name="hero-document"
              class="size-6 shrink-0 text-base-content/40"
            />
            <div class="min-w-0 flex-1">
              <a
                href={file_href(stored_file)}
                target="_blank"
                rel="noopener"
                class="block truncate text-sm font-medium hover:underline"
              >
                {stored_file.filename}
              </a>
              <p class="text-xs text-base-content/50">
                {format_bytes(stored_file.byte_size)}
              </p>
            </div>
            <button
              :if={stored_file.file_entry_id}
              phx-click="toggle_versions"
              phx-value-id={stored_file.id}
              class="btn btn-ghost btn-xs btn-square"
              title={gettext("Version history")}
            >
              <.icon name="hero-clock" class="size-4" />
            </button>
            <a
              href={~p"/files/#{stored_file.id}/download"}
              class="btn btn-ghost btn-xs btn-square"
              title={gettext("Download")}
            >
              <.icon name="hero-arrow-down-tray" class="size-4" />
            </a>
            <button
              :if={@can_manage? or stored_file.uploader_user_id == @current_scope.user.id}
              phx-click="delete_file"
              phx-value-id={stored_file.id}
              data-confirm={gettext("Delete this file permanently?")}
              class="btn btn-ghost btn-xs btn-square text-error"
              title={gettext("Delete")}
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </div>
          <div
            :if={@versions_for == stored_file.id and @versions != []}
            class="border-t border-base-200 px-3 py-2"
          >
            <p class="pb-1 text-xs font-medium uppercase tracking-wide text-base-content/50">
              {gettext("Version history")}
            </p>
            <div
              :for={version <- @versions}
              class="flex items-center gap-2 py-1 text-xs text-base-content/70"
            >
              <span class="truncate">
                {version.filename} · {format_bytes(version.byte_size)}
                <span :if={version.uploader_user}>· {version.uploader_user.display_name}</span>
                · {Calendar.strftime(version.inserted_at, "%Y-%m-%d %H:%M")}
                <span :if={version.id == stored_file.id} class="badge badge-ghost badge-xs">
                  {gettext("current")}
                </span>
              </span>
              <a
                href={~p"/files/#{version.id}/download"}
                class="btn btn-ghost btn-xs btn-square ml-auto"
                title={gettext("Download")}
              >
                <.icon name="hero-arrow-down-tray" class="size-3.5" />
              </a>
              <button
                :if={
                  length(@versions) > 1 and
                    (@can_manage? or version.uploader_user_id == @current_scope.user.id)
                }
                phx-click="delete_version"
                phx-value-id={version.id}
                data-confirm={gettext("Delete this version permanently?")}
                class="btn btn-ghost btn-xs btn-square text-error"
                title={gettext("Delete version")}
              >
                <.icon name="hero-trash" class="size-3.5" />
              </button>
            </div>
          </div>
        </div>
      </div>

      <.empty_state
        :if={@files == [] and (@collection != "browse" or @folders == [])}
        icon="hero-folder-open"
        headline={gettext("Nothing here yet")}
        description={
          if @can_write?,
            do: gettext("Upload the first file — sheet music, minutes, posters."),
            else: gettext("Files shared here will appear for everyone in this space.")
        }
      />

      <%!-- Contribution stats --%>
      <details :if={@contributions != []} class="pt-4">
        <summary class="cursor-pointer text-sm font-medium text-base-content/60">
          {gettext("Storage contributions")}
        </summary>
        <ul class="mt-2 space-y-1 text-sm">
          <li :for={contribution <- @contributions} class="flex items-center justify-between">
            <span>{(contribution.user && contribution.user.display_name) || gettext("Deleted user")}</span>
            <span class="text-base-content/60">{format_bytes(contribution.bytes)}</span>
          </li>
        </ul>
      </details>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    community = socket.assigns.active_community
    current_user = socket.assigns.current_scope.user

    scope_result =
      case params do
        %{"group_slug" => group_slug} ->
          with {:ok, group} <- Groups.fetch_viewable_group(current_user, community, group_slug),
               :ok <- Kammer.Authorization.feature_gate(group, :files) do
            {:ok, group, group.name, :groups}
          end

        _community_scope ->
          {:ok, community, community.name, :home}
      end

    case scope_result do
      {:ok, scope, space_name, scope_tab} ->
        {:ok,
         socket
         |> assign(:scope, scope)
         |> assign(:space_name, space_name)
         |> assign(:scope_tab, scope_tab)
         |> assign(:collection, "browse")
         |> assign(:versions_for, nil)
         |> assign(:versions, [])
         |> assign(:current_folder, nil)
         |> allow_upload(:files,
           accept: :any,
           max_entries: 10,
           max_file_size: Files.upload_limit_bytes()
         )
         |> reload()}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You are not allowed to do that."))
         |> push_navigate(to: ~p"/c/#{community.slug}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("switch_collection", %{"collection" => collection}, socket)
      when collection in ["browse", "images", "feed"] do
    {:noreply, socket |> assign(:collection, collection) |> reload()}
  end

  def handle_event("open_folder", %{"id" => folder_id}, socket) do
    folder = if folder_id == "", do: nil, else: Files.get_folder(socket.assigns.scope, folder_id)
    {:noreply, socket |> assign(:current_folder, folder) |> reload()}
  end

  def handle_event("create_folder", %{"name" => name}, socket) do
    current_user = socket.assigns.current_scope.user

    case Files.create_folder(
           current_user,
           socket.assigns.scope,
           socket.assigns.current_folder,
           name
         ) do
      {:ok, _folder} ->
        {:noreply, reload(socket)}

      {:error, :too_deep} ->
        {:noreply, put_flash(socket, :error, gettext("Folders can't nest deeper than this."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("toggle_read_override", %{"id" => folder_id}, socket) do
    toggle_override(socket, folder_id, :read_override)
  end

  def handle_event("toggle_write_override", %{"id" => folder_id}, socket) do
    toggle_override(socket, folder_id, :write_override)
  end

  def handle_event("delete_folder", %{"id" => folder_id}, socket) do
    current_user = socket.assigns.current_scope.user
    folder = Files.get_folder(socket.assigns.scope, folder_id)

    with %Folder{} <- folder,
         {:ok, _deleted} <- Files.delete_folder(current_user, socket.assigns.scope, folder) do
      {:noreply, reload(socket)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("toggle_versions", %{"id" => file_id}, socket) do
    if socket.assigns.versions_for == file_id do
      {:noreply, socket |> assign(:versions_for, nil) |> assign(:versions, [])}
    else
      stored_file = Enum.find(socket.assigns.files, &(&1.id == file_id))

      case stored_file && Files.list_versions(socket.assigns.current_scope.user, stored_file) do
        {:ok, versions} ->
          {:noreply, socket |> assign(:versions_for, file_id) |> assign(:versions, versions)}

        _not_visible ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("delete_version", %{"id" => version_id}, socket) do
    version = Enum.find(socket.assigns.versions, &(&1.id == version_id))

    case version && Files.delete_version(socket.assigns.current_scope.user, version) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> assign(:versions_for, nil)
         |> assign(:versions, [])
         |> put_flash(:info, gettext("Version deleted."))
         |> reload()}

      {:error, :last_version} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The only version cannot be deleted — delete the file instead.")
         )}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("delete_file", %{"id" => file_id}, socket) do
    current_user = socket.assigns.current_scope.user

    with {:ok, stored_file} <- Files.fetch_accessible_file(current_user, file_id),
         {:ok, _deleted} <- Files.delete_file(current_user, stored_file) do
      {:noreply, reload(socket)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload", _params, socket) do
    current_user = socket.assigns.current_scope.user
    scope = socket.assigns.scope
    folder = socket.assigns.current_folder

    results =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        case Files.upload_to_space(current_user, scope, folder, path, %{
               filename: entry.client_name,
               content_type: entry.client_type
             }) do
          {:ok, stored_file} -> {:ok, {:ok, stored_file}}
          {:error, reason} -> {:ok, {:error, reason}}
        end
      end)

    socket =
      cond do
        Enum.any?(results, &match?({:error, :quota_exceeded}, &1)) ->
          put_flash(
            socket,
            :error,
            gettext("Storage quota reached — ask an admin to raise it or free some space.")
          )

        Enum.any?(results, &match?({:error, :rate_limited}, &1)) ->
          put_flash(socket, :error, gettext("Too many uploads — please try again later."))

        true ->
          socket
      end

    {:noreply, reload(socket)}
  end

  defp toggle_override(socket, folder_id, override_field) do
    current_user = socket.assigns.current_scope.user
    folder = Files.get_folder(socket.assigns.scope, folder_id)

    if folder do
      new_value =
        if Map.fetch!(folder, override_field) == :admins_only, do: :inherit, else: :admins_only

      case Files.update_folder_overrides(current_user, socket.assigns.scope, folder, %{
             override_field => new_value
           }) do
        {:ok, _folder} ->
          {:noreply, reload(socket)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
      end
    else
      {:noreply, socket}
    end
  end

  defp reload(socket) do
    current_user = socket.assigns.current_scope.user
    scope = socket.assigns.scope
    folder = socket.assigns.current_folder
    relationship = Authorization.relationship(current_user, scope)
    chain = Files.folder_chain(folder)

    {folders, files} =
      case socket.assigns.collection do
        "browse" ->
          files =
            case Files.list_files(current_user, scope, folder) do
              {:ok, files} -> files
              {:error, :unauthorized} -> []
            end

          {Files.list_folders(current_user, scope, folder), files}

        "images" ->
          {[], Files.list_image_collection(current_user, scope)}

        "feed" ->
          {[], Files.list_feed_collection(current_user, scope)}
      end

    socket
    |> assign(:folders, folders)
    |> assign(:files, files)
    |> assign(:folder_chain, chain)
    |> assign(
      :can_write?,
      Authorization.can_write_folder?(current_user, scope, chain, relationship)
    )
    |> assign(:can_manage?, Authorization.can_manage_files?(current_user, scope, relationship))
    |> assign(:usage_bytes, Files.space_usage_bytes(scope))
    |> assign(:quota_bytes, Files.effective_quota_bytes(scope))
    |> assign(:contributions, Files.contribution_stats(scope))
  end

  defp collection_tabs do
    [
      {"browse", gettext("Browse")},
      {"images", gettext("Images")},
      {"feed", gettext("Posted in feed")}
    ]
  end

  defp file_href(stored_file) do
    if stored_file.kind == :image do
      ~p"/files/#{stored_file.id}"
    else
      ~p"/files/#{stored_file.id}/download"
    end
  end

  defp format_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes) when bytes >= 1024, do: "#{div(bytes, 1024)} kB"
  defp format_bytes(bytes), do: "#{bytes} B"
end
