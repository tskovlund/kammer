defmodule KammerWeb.GroupLive.Show do
  @moduledoc """
  Group page: header with visibility/sealed/archived state, description,
  membership actions (join / request / leave), and members. Everything
  the actor sees here passed `Kammer.Authorization` — including whether
  the page renders at all.
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

  alias Kammer.Authorization
  alias Kammer.Groups

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_community={member_of_community?(@community_relationship) && @active_community}
      member_communities={@member_communities}
      member_groups={@member_groups}
      community_relationship={@community_relationship}
      current_tab={:groups}
    >
      <.header>
        {@group.name}
        <:subtitle>
          <span class="flex flex-wrap items-center gap-1.5">
            <.visibility_badge visibility={@group.visibility} />
            <span :if={@group.sealed} class="badge badge-ghost badge-sm">
              {gettext("Sealed")}
            </span>
            <span :if={Kammer.Groups.Group.archived?(@group)} class="badge badge-warning badge-sm">
              {gettext("Archived")}
            </span>
            <span class="text-base-content/50">
              · {ngettext("%{count} member", "%{count} members", length(@members))}
            </span>
          </span>
        </:subtitle>
        <:actions>
          <.link
            :if={@permissions.manage}
            navigate={~p"/c/#{@active_community.slug}/g/#{@group.slug}/settings"}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-cog-6-tooth" class="size-4" /> {gettext("Settings")}
          </.link>
        </:actions>
      </.header>

      <p :if={@group.description} class="text-base-content/80">{@group.description}</p>

      <div
        :if={@group.sealed}
        class="rounded-box border border-base-300 p-3 text-sm text-base-content/60"
      >
        {gettext(
          "Sealed: hidden from community admins. The server operator can still technically access all data."
        )}
      </div>

      <div class="flex flex-wrap gap-2">
        <.button :if={@permissions.join} phx-click="join" class="btn btn-primary btn-sm">
          {gettext("Join group")}
        </.button>
        <.button
          :if={@permissions.request_to_join and not @pending_request?}
          phx-click="request_to_join"
          class="btn btn-primary btn-sm"
        >
          {gettext("Request to join")}
        </.button>
        <span :if={@pending_request?} class="badge badge-ghost">
          {gettext("Join request pending")}
        </span>
        <.button
          :if={@membership && @membership.role != :owner}
          phx-click="leave"
          data-confirm={gettext("Leave this group?")}
          class="btn btn-ghost btn-sm"
        >
          {gettext("Leave group")}
        </.button>
      </div>

      <section class="pt-4">
        <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Feed")}
        </h2>
        <.empty_state
          icon="hero-chat-bubble-left-right"
          headline={gettext("No posts yet")}
          description={
            if Kammer.Groups.Group.archived?(@group),
              do: gettext("This group is archived and read-only."),
              else: gettext("Be the first to write something when posting opens here.")
          }
        />
      </section>

      <section :if={@members != []} class="pt-4">
        <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Members")}
        </h2>
        <ul class="space-y-1">
          <li
            :for={membership <- @members}
            class="flex items-center gap-3 rounded-field px-2 py-1.5"
          >
            <.user_avatar user={membership.user} size_class="size-8" text_class="text-xs" />
            <span class="truncate">{membership.user.display_name}</span>
            <span :if={membership.role != :member} class="badge badge-ghost badge-sm">
              {role_label(membership.role)}
            </span>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"group_slug" => group_slug}, _session, socket) do
    current_user = current_user(socket)
    community = socket.assigns.active_community

    case Groups.fetch_viewable_group(current_user, community, group_slug) do
      {:ok, group} ->
        {:ok, socket |> assign(:group, group) |> refresh(current_user)}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Group not found."))
         |> push_navigate(to: ~p"/c/#{community.slug}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("join", _params, socket) do
    current_user = current_user(socket)

    case Groups.join_group(current_user, socket.assigns.group) do
      {:ok, _membership} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Welcome to the group!")) |> refresh(current_user)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("request_to_join", _params, socket) do
    current_user = current_user(socket)

    case Groups.request_to_join(current_user, socket.assigns.group) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Request sent — an admin will review it."))
         |> refresh(current_user)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("leave", _params, socket) do
    current_user = current_user(socket)

    case Groups.leave_group(current_user, socket.assigns.group) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("You left the group."))
         |> push_navigate(to: ~p"/c/#{socket.assigns.active_community.slug}/groups")}

      {:error, :owner_cannot_leave} ->
        {:noreply,
         put_flash(socket, :error, gettext("Owners must transfer ownership before leaving."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  defp refresh(socket, current_user) do
    group = socket.assigns.group
    relationship = Authorization.relationship(current_user, group)

    members =
      case Groups.list_members(current_user, group) do
        {:ok, members} -> members
        {:error, :unauthorized} -> []
      end

    permissions = %{
      join: Authorization.can?(current_user, :join_group, group, relationship),
      request_to_join:
        Authorization.can?(current_user, :request_to_join_group, group, relationship),
      manage: Authorization.can?(current_user, :manage_group, group, relationship)
    }

    socket
    |> assign(:membership, Groups.get_membership(group, current_user))
    |> assign(:pending_request?, Groups.pending_join_request?(current_user, group))
    |> assign(:members, members)
    |> assign(:permissions, permissions)
  end

  defp current_user(socket) do
    case socket.assigns[:current_scope] do
      %{user: user} -> user
      _no_scope -> nil
    end
  end

  defp member_of_community?(%{community_role: role}), do: role != nil
  defp member_of_community?(_relationship), do: false

  defp role_label(:owner), do: gettext("Owner")
  defp role_label(:admin), do: gettext("Admin")
  defp role_label(:member), do: gettext("Member")
end
