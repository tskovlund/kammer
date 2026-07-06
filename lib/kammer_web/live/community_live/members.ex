defmodule KammerWeb.CommunityLive.Members do
  @moduledoc """
  Member directory of the active community (SPEC §4). Custom-field
  filtering (the band roster) arrives in Phase 2; the base directory
  lists members with roles, and admins manage roles and removal here.
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

  alias Kammer.Authorization
  alias Kammer.Communities

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
      current_tab={:members}
    >
      <.header>
        {gettext("Members")}
        <:subtitle>
          {ngettext("%{count} member", "%{count} members", length(@members))}
        </:subtitle>
      </.header>

      <ul class="space-y-1">
        <li
          :for={membership <- @members}
          class="flex items-center gap-3 rounded-field px-2 py-2"
        >
          <.user_avatar user={membership.user} size_class="size-9" />
          <div class="min-w-0 flex-1">
            <p class="truncate font-medium">{membership.user.display_name}</p>
          </div>
          <span :if={membership.role != :member} class="badge badge-ghost badge-sm">
            {role_label(membership.role)}
          </span>
          <div :if={@can_manage? and membership.user_id != @current_scope.user.id}>
            <.button
              :if={membership.role == :member}
              phx-click="promote"
              phx-value-id={membership.id}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Make admin")}
            </.button>
            <.button
              :if={membership.role == :admin}
              phx-click="demote"
              phx-value-id={membership.id}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Remove admin")}
            </.button>
            <.button
              :if={membership.role != :owner}
              phx-click="remove"
              phx-value-id={membership.id}
              data-confirm={gettext("Remove this member from the community and all its groups?")}
              class="btn btn-ghost btn-xs text-error"
            >
              {gettext("Remove")}
            </.button>
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    can_manage? = Authorization.can?(current_user, :manage_community, community)

    {:ok, socket |> assign(:can_manage?, can_manage?) |> load_members(current_user)}
  end

  @impl Phoenix.LiveView
  def handle_event("promote", %{"id" => membership_id}, socket) do
    change_role(socket, membership_id, :admin)
  end

  def handle_event("demote", %{"id" => membership_id}, socket) do
    change_role(socket, membership_id, :member)
  end

  def handle_event("remove", %{"id" => membership_id}, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community
    membership = find_membership(socket, membership_id)

    with %{} <- membership,
         {:ok, _removed} <- Communities.remove_member(current_user, community, membership) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Member removed."))
       |> load_members(current_user)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  defp change_role(socket, membership_id, new_role) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community
    membership = find_membership(socket, membership_id)

    with %{} <- membership,
         {:ok, _updated} <-
           Communities.update_member_role(current_user, community, membership, new_role) do
      {:noreply, load_members(socket, current_user)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  defp find_membership(socket, membership_id) do
    Enum.find(socket.assigns.members, fn membership -> membership.id == membership_id end)
  end

  defp load_members(socket, current_user) do
    members =
      case Communities.list_members(current_user, socket.assigns.active_community) do
        {:ok, members} -> members
        {:error, :unauthorized} -> []
      end

    assign(socket, :members, members)
  end

  defp role_label(:owner), do: gettext("Owner")
  defp role_label(:admin), do: gettext("Admin")
  defp role_label(:member), do: gettext("Member")
end
