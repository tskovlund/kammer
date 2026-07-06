defmodule KammerWeb.GroupLive.Settings do
  @moduledoc """
  Group administration: settings (sealed is shown but never editable —
  irreversible, ADR 0005), join requests, invite links, member roles,
  archive/unarchive, and deletion.
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents, only: [visibility_label: 1, user_avatar: 1]

  alias Kammer.Authorization
  alias Kammer.Groups
  alias Kammer.Groups.Group
  alias Kammer.Invitations

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
      current_tab={:groups}
    >
      <.header>
        {gettext("Group settings")}
        <:subtitle>{@group.name}</:subtitle>
        <:actions>
          <.link
            navigate={~p"/c/#{@active_community.slug}/g/#{@group.slug}"}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Back to group")}
          </.link>
        </:actions>
      </.header>

      <.form for={@form} id="group_settings_form" phx-submit="save" phx-change="validate">
        <.input field={@form[:name]} type="text" label={gettext("Name")} required />
        <.input field={@form[:slug]} type="text" label={gettext("Web address")} required />
        <.input field={@form[:description]} type="textarea" label={gettext("Description")} />
        <.input
          field={@form[:visibility]}
          type="select"
          label={gettext("Visibility")}
          options={visibility_options()}
        />
        <.input
          field={@form[:join_policy]}
          type="select"
          label={gettext("Who can join")}
          options={[
            {gettext("Anyone in the community"), "open"},
            {gettext("Request with approval"), "request_approval"},
            {gettext("Invite only"), "invite_only"}
          ]}
        />
        <.input
          field={@form[:posting_policy]}
          type="select"
          label={gettext("Who can post")}
          options={[
            {gettext("All members"), "all_members"},
            {gettext("Admins only (announcement group)"), "admins_only"}
          ]}
        />
        <.input
          field={@form[:comment_policy]}
          type="select"
          label={gettext("Comments")}
          options={[
            {gettext("Members"), "members"},
            {gettext("Members and guests"), "members_and_guests"},
            {gettext("Off"), "off"}
          ]}
        />
        <.input
          field={@form[:version_retention]}
          type="number"
          min="1"
          label={gettext("File versions to keep (empty = unlimited)")}
        />

        <.input
          field={@form[:approval_queue]}
          type="checkbox"
          label={gettext("Posts require admin approval")}
        />

        <p
          :if={@group.sealed}
          class="rounded-box border border-base-300 p-3 text-sm text-base-content/60"
        >
          {gettext("This group is sealed. Sealing is permanent and cannot be changed.")}
        </p>

        <.button variant="primary" phx-disable-with={gettext("Saving...")}>
          {gettext("Save settings")}
        </.button>
      </.form>

      <section class="pt-6">
        <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Features")}
        </h2>
        <p class="pb-3 text-sm text-base-content/70">
          {gettext(
            "Choose which tools this group shows. Turning a feature off hides it — nothing is deleted, and turning it back on restores everything."
          )}
        </p>
        <form id="group-features-form" phx-change="save_features" class="space-y-2">
          <label class="flex items-center gap-2 text-sm text-base-content/50">
            <input type="checkbox" checked disabled class="checkbox checkbox-sm" />
            {gettext("Feed")}
            <span class="text-xs">({gettext("always on")})</span>
          </label>
          <label
            :for={feature <- Kammer.Groups.Group.toggleable_features()}
            class="flex cursor-pointer items-center gap-2 text-sm"
          >
            <input
              type="checkbox"
              name="features[]"
              value={feature}
              checked={Kammer.Groups.Group.feature_enabled?(@group, feature)}
              class="checkbox checkbox-sm"
            />
            {feature_label(feature)}
          </label>
          <input type="hidden" name="features[]" value="feed" />
        </form>
      </section>

      <section :if={@join_requests != []} class="pt-6">
        <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Join requests")}
        </h2>
        <ul class="space-y-2">
          <li
            :for={request <- @join_requests}
            class="flex items-center gap-3 rounded-box border border-base-200 p-3"
          >
            <.user_avatar user={request.user} size_class="size-8" text_class="text-xs" />
            <div class="min-w-0 flex-1">
              <p class="truncate font-medium">{request.user.display_name}</p>
              <p :if={request.message} class="truncate text-sm text-base-content/60">
                {request.message}
              </p>
            </div>
            <.button
              phx-click="approve_request"
              phx-value-id={request.id}
              class="btn btn-primary btn-sm"
            >
              {gettext("Approve")}
            </.button>
            <.button phx-click="deny_request" phx-value-id={request.id} class="btn btn-ghost btn-sm">
              {gettext("Deny")}
            </.button>
          </li>
        </ul>
      </section>

      <section class="pt-6">
        <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Invite links")}
        </h2>
        <ul :if={@invites != []} class="space-y-2 pb-3">
          <li
            :for={invite <- @invites}
            class="flex items-center gap-3 rounded-box border border-base-200 p-3 text-sm"
          >
            <code class="min-w-0 flex-1 truncate">{url(~p"/invite/#{invite.token}")}</code>
            <span class="whitespace-nowrap text-base-content/50">
              {invite_usage(invite)}
            </span>
            <.button phx-click="revoke_invite" phx-value-id={invite.id} class="btn btn-ghost btn-xs">
              {gettext("Revoke")}
            </.button>
          </li>
        </ul>
        <.button phx-click="create_invite" class="btn btn-ghost btn-sm">
          <.icon name="hero-link" class="size-4" /> {gettext("Create invite link")}
        </.button>
      </section>

      <section class="space-y-3 pt-8">
        <h2 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Danger zone")}
        </h2>
        <div class="flex flex-wrap gap-2">
          <.button
            :if={!Group.archived?(@group)}
            phx-click="archive"
            data-confirm={
              gettext("Archive this group? It becomes read-only and hidden from active lists.")
            }
            class="btn btn-outline btn-sm"
          >
            {gettext("Archive group")}
          </.button>
          <.button :if={Group.archived?(@group)} phx-click="unarchive" class="btn btn-outline btn-sm">
            {gettext("Unarchive group")}
          </.button>
          <.button
            :if={@can_delete?}
            phx-click="delete"
            data-confirm={gettext("Delete this group and ALL of its content? This cannot be undone.")}
            class="btn btn-error btn-outline btn-sm"
          >
            {gettext("Delete group")}
          </.button>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"group_slug" => group_slug}, _session, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    with {:ok, group} <- Groups.fetch_viewable_group(current_user, community, group_slug),
         :ok <- Authorization.authorize(current_user, :manage_group, group) do
      {:ok,
       socket
       |> assign(:group, group)
       |> assign(:form, to_form(Groups.change_group(group)))
       |> assign(:can_delete?, Authorization.can?(current_user, :delete_group, group))
       |> load_admin_lists(current_user)}
    else
      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You are not allowed to do that."))
         |> push_navigate(to: ~p"/c/#{community.slug}/groups")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"group" => group_params}, socket) do
    changeset =
      socket.assigns.group
      |> Groups.change_group(group_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"group" => group_params}, socket) do
    current_user = socket.assigns.current_scope.user

    case Groups.update_group(current_user, socket.assigns.group, group_params) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Settings saved."))
         |> assign(:group, %Group{group | community: socket.assigns.active_community})
         |> assign(:form, to_form(Groups.change_group(group)))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("save_features", params, socket) do
    features = Map.get(params, "features", [])

    case Groups.update_group_features(
           socket.assigns.current_scope.user,
           socket.assigns.group,
           features
         ) do
      {:ok, group} ->
        {:noreply,
         socket
         |> assign(:group, group)
         |> put_flash(:info, gettext("Features updated."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("approve_request", %{"id" => request_id}, socket) do
    with_request(socket, request_id, fn request, current_user ->
      Groups.approve_join_request(current_user, socket.assigns.group, request)
    end)
  end

  def handle_event("deny_request", %{"id" => request_id}, socket) do
    with_request(socket, request_id, fn request, current_user ->
      Groups.deny_join_request(current_user, socket.assigns.group, request)
    end)
  end

  def handle_event("create_invite", _params, socket) do
    current_user = socket.assigns.current_scope.user

    case Invitations.create_group_invite(current_user, socket.assigns.group) do
      {:ok, _invite} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Invite link created."))
         |> load_admin_lists(current_user)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("revoke_invite", %{"id" => invite_id}, socket) do
    current_user = socket.assigns.current_scope.user

    invite = Enum.find(socket.assigns.invites, fn invite -> invite.id == invite_id end)

    if invite do
      case Invitations.revoke_invite(current_user, invite) do
        {:ok, _revoked} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Invite revoked."))
           |> load_admin_lists(current_user)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("archive", _params, socket) do
    current_user = socket.assigns.current_scope.user

    case Groups.archive_group(current_user, socket.assigns.group) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Group archived."))
         |> assign(:group, %Group{group | community: socket.assigns.active_community})}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("unarchive", _params, socket) do
    current_user = socket.assigns.current_scope.user

    case Groups.unarchive_group(current_user, socket.assigns.group) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Group unarchived."))
         |> assign(:group, %Group{group | community: socket.assigns.active_community})}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("delete", _params, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    case Groups.delete_group(current_user, socket.assigns.group) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Group deleted."))
         |> push_navigate(to: ~p"/c/#{community.slug}/groups")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  defp with_request(socket, request_id, action) do
    current_user = socket.assigns.current_scope.user

    request =
      Enum.find(socket.assigns.join_requests, fn request -> request.id == request_id end)

    if request do
      case action.(request, current_user) do
        {:ok, _result} ->
          {:noreply, load_admin_lists(socket, current_user)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
      end
    else
      {:noreply, socket}
    end
  end

  defp load_admin_lists(socket, current_user) do
    group = socket.assigns.group

    join_requests =
      case Groups.list_pending_join_requests(current_user, group) do
        {:ok, requests} -> requests
        {:error, :unauthorized} -> []
      end

    invites =
      case Invitations.list_invites(current_user, group) do
        {:ok, invites} -> invites
        {:error, :unauthorized} -> []
      end

    socket
    |> assign(:join_requests, join_requests)
    |> assign(:invites, invites)
  end

  defp invite_usage(invite) do
    used = gettext("%{count} used", count: invite.use_count)

    case invite.max_uses do
      nil -> used
      max_uses -> "#{invite.use_count}/#{max_uses}"
    end
  end

  defp visibility_options do
    Enum.map(Group.visibilities(), fn visibility ->
      {visibility_label(visibility), Atom.to_string(visibility)}
    end)
  end

  defp feature_label(:events), do: gettext("Events")
  defp feature_label(:files), do: gettext("Files")
  defp feature_label(:availability), do: gettext("Date finding")
  defp feature_label(:assignments), do: gettext("Assignments")
  defp feature_label(feature), do: feature |> Atom.to_string() |> String.capitalize()
end
