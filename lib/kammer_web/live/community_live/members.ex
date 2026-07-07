defmodule KammerWeb.CommunityLive.Members do
  @moduledoc """
  Member directory of the active community (SPEC §4): the base list
  with roles, admin role/removal management, each member's visible
  contact info and custom field answers, and filter dropdowns for
  single-choice custom fields — the roster.
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

  alias Kammer.Accounts
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
      unread_notifications={@unread_notifications}
      current_tab={:members}
    >
      <.header>
        {gettext("Members")}
        <:subtitle>
          {ngettext("%{count} member", "%{count} members", length(@members))}
        </:subtitle>
      </.header>

      <div :if={@filterable_fields != []} class="flex flex-wrap gap-2 pb-3">
        <form :for={field <- @filterable_fields} id={"filter-#{field.id}"} phx-change="filter">
          <input type="hidden" name="field_id" value={field.id} />
          <select name="value" class="select select-sm select-bordered">
            <option value="">{field.label}: {gettext("All")}</option>
            <option
              :for={choice <- field.options}
              value={choice}
              selected={@active_filters[field.id] == choice}
            >
              {choice}
            </option>
          </select>
        </form>
      </div>

      <ul class="space-y-1">
        <li
          :for={row <- @members}
          class="flex items-center gap-3 rounded-field px-2 py-2"
        >
          <.user_avatar user={row.membership.user} size_class="size-9" />
          <div class="min-w-0 flex-1">
            <p class="truncate font-medium">{row.membership.user.display_name}</p>
            <p :if={row.visible_fields != []} class="truncate text-xs text-base-content/60">
              {Enum.map_join(row.visible_fields, " · ", fn {label, value} -> "#{label}: #{value}" end)}
            </p>
          </div>
          <span :if={row.membership.role != :member} class="badge badge-ghost badge-sm">
            {role_label(row.membership.role)}
          </span>
          <div :if={@can_manage? and row.membership.user_id != @current_scope.user.id}>
            <.button
              :if={row.membership.role == :member}
              phx-click="promote"
              phx-value-id={row.membership.id}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Make admin")}
            </.button>
            <.button
              :if={row.membership.role == :admin}
              phx-click="demote"
              phx-value-id={row.membership.id}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Remove admin")}
            </.button>
            <.button
              :if={row.membership.role != :owner}
              phx-click="remove"
              phx-value-id={row.membership.id}
              data-confirm={gettext("Remove this member from the community and all its groups?")}
              class="btn btn-ghost btn-xs text-error"
            >
              {gettext("Remove")}
            </.button>
            <.button
              :if={row.membership.role == :member}
              id={"ban-#{row.membership.id}"}
              phx-click="ban"
              phx-value-id={row.membership.id}
              data-confirm={
                gettext(
                  "Ban this member? They are removed everywhere and their email cannot rejoin until the ban is lifted (Moderation page)."
                )
              }
              class="btn btn-ghost btn-xs text-error"
            >
              {gettext("Ban")}
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
    viewer_role = Authorization.relationship(current_user, community).community_role

    filterable_fields =
      community
      |> Communities.list_visible_custom_fields(viewer_role)
      |> Enum.filter(&(&1.field_type == :single_select))

    {:ok,
     socket
     |> assign(:can_manage?, can_manage?)
     |> assign(:viewer_role, viewer_role)
     |> assign(:filterable_fields, filterable_fields)
     |> assign(:active_filters, %{})
     |> load_members(current_user)}
  end

  @impl Phoenix.LiveView
  def handle_event("filter", %{"field_id" => field_id, "value" => ""}, socket) do
    active_filters = Map.delete(socket.assigns.active_filters, field_id)

    {:noreply,
     socket
     |> assign(:active_filters, active_filters)
     |> load_members(socket.assigns.current_scope.user)}
  end

  def handle_event("filter", %{"field_id" => field_id, "value" => value}, socket) do
    active_filters = Map.put(socket.assigns.active_filters, field_id, value)

    {:noreply,
     socket
     |> assign(:active_filters, active_filters)
     |> load_members(socket.assigns.current_scope.user)}
  end

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

  def handle_event("ban", %{"id" => membership_id}, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community
    membership = find_membership(socket, membership_id)

    with %{} <- membership,
         {:ok, _ban} <-
           Kammer.Moderation.ban_member(current_user, community, membership.user, nil) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Member banned — manage bans on the Moderation page."))
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
    case Enum.find(socket.assigns.members, fn row -> row.membership.id == membership_id end) do
      nil -> nil
      row -> row.membership
    end
  end

  defp load_members(socket, current_user) do
    community = socket.assigns.active_community
    viewer_role = socket.assigns.viewer_role
    active_filters = socket.assigns.active_filters

    memberships =
      case Communities.list_members(current_user, community) do
        {:ok, memberships} -> memberships
        {:error, :unauthorized} -> []
      end

    values_by_user =
      Communities.custom_field_values_by_user(community, Enum.map(memberships, & &1.user))

    visible_field_defs = Communities.list_visible_custom_fields(community, viewer_role)

    rows =
      memberships
      |> Enum.filter(&matches_filters?(&1, values_by_user, active_filters))
      |> Enum.map(&build_row(&1, viewer_role, visible_field_defs, values_by_user))

    assign(socket, :members, rows)
  end

  defp matches_filters?(_membership, _values_by_user, filters) when map_size(filters) == 0,
    do: true

  defp matches_filters?(membership, values_by_user, filters) do
    member_values = Map.get(values_by_user, membership.user_id, %{})
    Enum.all?(filters, fn {field_id, value} -> Map.get(member_values, field_id) == value end)
  end

  defp build_row(membership, viewer_role, visible_field_defs, values_by_user) do
    contact_fields =
      membership.user
      |> Accounts.visible_contact_fields(viewer_role)
      |> Enum.map(fn {key, value} -> {contact_label(key), value} end)

    member_values = Map.get(values_by_user, membership.user_id, %{})

    custom_fields =
      Enum.flat_map(visible_field_defs, fn field ->
        case Map.fetch(member_values, field.id) do
          {:ok, value} -> [{field.label, value}]
          :error -> []
        end
      end)

    %{membership: membership, visible_fields: contact_fields ++ custom_fields}
  end

  defp contact_label(:phone), do: gettext("Phone")
  defp contact_label(:email), do: gettext("Email")
  defp contact_label(:note), do: gettext("Contact")

  defp role_label(:owner), do: gettext("Owner")
  defp role_label(:admin), do: gettext("Admin")
  defp role_label(:member), do: gettext("Member")
end
