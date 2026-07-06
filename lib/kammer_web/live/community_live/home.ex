defmodule KammerWeb.CommunityLive.Home do
  @moduledoc """
  Community home. Members see their home surface (the aggregated feed
  arrives with the feed step; until then, their groups). Non-members and
  visitors see the community's public page: name, description, and its
  `public_listed` groups (SPEC §3).
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
      active_community={member?(@community_relationship) && @active_community}
      member_communities={@member_communities}
      member_groups={@member_groups}
      community_relationship={@community_relationship}
      current_tab={:home}
    >
      <%= if member?(@community_relationship) do %>
        <.header>
          {@active_community.name}
          <:subtitle :if={@active_community.description}>
            {@active_community.description}
          </:subtitle>
        </.header>

        <section :if={@member_groups != []} class="space-y-2">
          <h2 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
            {gettext("Your groups")}
          </h2>
          <.link
            :for={group <- @member_groups}
            navigate={~p"/c/#{@active_community.slug}/g/#{group.slug}"}
            class="flex items-center gap-3 rounded-box border border-base-200 p-4 hover:bg-base-200"
          >
            <div class="min-w-0">
              <p class="truncate font-medium">{group.name}</p>
              <p :if={group.description} class="truncate text-sm text-base-content/60">
                {group.description}
              </p>
            </div>
            <.visibility_badge visibility={group.visibility} />
          </.link>
        </section>

        <.empty_state
          :if={@member_groups == []}
          icon="hero-user-group"
          headline={gettext("You haven't joined any groups yet")}
          description={gettext("Groups are where posts, events, and files live.")}
        >
          <:action>
            <.link navigate={~p"/c/#{@active_community.slug}/groups"} class="btn btn-primary btn-sm">
              {gettext("Browse groups")}
            </.link>
          </:action>
        </.empty_state>
      <% else %>
        <%!-- Public community page --%>
        <div class="space-y-6 py-4">
          <.header>
            {@active_community.name}
            <:subtitle :if={@active_community.description}>
              {@active_community.description}
            </:subtitle>
          </.header>

          <div :if={@public_groups != []} class="space-y-2">
            <h2 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
              {gettext("Public groups")}
            </h2>
            <.link
              :for={group <- @public_groups}
              navigate={~p"/c/#{@active_community.slug}/g/#{group.slug}"}
              class="flex items-center gap-3 rounded-box border border-base-200 p-4 hover:bg-base-200"
            >
              <div class="min-w-0">
                <p class="truncate font-medium">{group.name}</p>
                <p :if={group.description} class="truncate text-sm text-base-content/60">
                  {group.description}
                </p>
              </div>
            </.link>
          </div>

          <div class="rounded-box border border-base-200 p-4 text-sm text-base-content/70">
            <%= if @current_scope && @current_scope.user do %>
              {gettext("Membership is by invitation — ask an organizer for an invite link.")}
            <% else %>
              {gettext("Already a member?")}
              <.link navigate={~p"/users/log-in"} class="link font-medium">
                {gettext("Sign in")}
              </.link>
            <% end %>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      if member?(socket.assigns.community_relationship) do
        assign(socket, :public_groups, [])
      else
        assign(socket, :public_groups, Groups.list_public_groups(socket.assigns.active_community))
      end

    {:ok, socket}
  end

  defp member?(%{community_role: role}), do: role != nil
  defp member?(_relationship), do: false
end
