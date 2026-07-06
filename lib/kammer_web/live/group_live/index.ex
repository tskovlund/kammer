defmodule KammerWeb.GroupLive.Index do
  @moduledoc """
  Group directory of the active community: active groups the actor may
  see (visibility filtering in `Kammer.Authorization`), with archived
  groups browsable in their own section (SPEC §3).
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

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
      current_tab={:groups}
    >
      <.header>
        {gettext("Groups")}
        <:actions>
          <.link navigate={~p"/c/#{@active_community.slug}/groups/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="size-4" /> {gettext("New group")}
          </.link>
        </:actions>
      </.header>

      <div :if={@active_groups != []} class="space-y-2">
        <.link
          :for={group <- @active_groups}
          navigate={~p"/c/#{@active_community.slug}/g/#{group.slug}"}
          class="flex items-center gap-3 rounded-box border border-base-200 p-4 hover:bg-base-200"
        >
          <div class="min-w-0 flex-1">
            <p class="truncate font-medium">
              {group.name}
              <span :if={group.sealed} class="badge badge-ghost badge-sm ml-1">
                {gettext("Sealed")}
              </span>
            </p>
            <p :if={group.description} class="truncate text-sm text-base-content/60">
              {group.description}
            </p>
          </div>
          <.visibility_badge visibility={group.visibility} />
        </.link>
      </div>

      <.empty_state
        :if={@active_groups == []}
        icon="hero-user-group"
        headline={gettext("No groups yet")}
        description={gettext("Create the first group — a band, a committee, a project.")}
      >
        <:action>
          <.link navigate={~p"/c/#{@active_community.slug}/groups/new"} class="btn btn-primary btn-sm">
            {gettext("New group")}
          </.link>
        </:action>
      </.empty_state>

      <details :if={@archived_groups != []} class="pt-6">
        <summary class="cursor-pointer text-sm font-medium text-base-content/60">
          {gettext("Archived groups")} ({length(@archived_groups)})
        </summary>
        <div class="mt-2 space-y-2">
          <.link
            :for={group <- @archived_groups}
            navigate={~p"/c/#{@active_community.slug}/g/#{group.slug}"}
            class="flex items-center gap-3 rounded-box border border-base-200 p-4 opacity-70 hover:bg-base-200"
          >
            <div class="min-w-0 flex-1">
              <p class="truncate font-medium">{group.name}</p>
            </div>
            <span class="badge badge-ghost badge-sm">{gettext("Archived")}</span>
          </.link>
        </div>
      </details>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    {:ok,
     socket
     |> assign(:active_groups, Groups.list_active_groups(current_user, community))
     |> assign(:archived_groups, Groups.list_archived_groups(current_user, community))}
  end
end
