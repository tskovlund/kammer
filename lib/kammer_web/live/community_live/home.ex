defmodule KammerWeb.CommunityLive.Home do
  @moduledoc """
  Community home. Members see their home surface (the aggregated feed
  arrives with the feed step; until then, their groups). Non-members and
  visitors see the community's public page: name, description, and its
  `public_listed` groups (SPEC §3).
  """

  use KammerWeb, :live_view

  import KammerWeb.FeedComponents
  import KammerWeb.KammerComponents

  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Feed
  alias Kammer.Groups
  alias KammerWeb.FeedEventHandlers

  @feed_events ~w(toggle_reaction create_comment delete_comment vote_poll acknowledge
                  show_acknowledgment_status toggle_pin toggle_comment_lock approve_post
                  soft_delete_post hard_delete_post set_feed_sort)

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_community={
        Authorization.can?(
          @current_scope,
          :view_community,
          @active_community,
          @community_relationship
        ) && @active_community
      }
      member_communities={@member_communities}
      member_groups={@member_groups}
      community_relationship={@community_relationship}
      unread_notifications={@unread_notifications}
      current_tab={:home}
    >
      <%= if Authorization.can?(@current_scope, :view_community, @active_community, @community_relationship) do %>
        <div
          :if={@missing_required_fields != []}
          class="alert alert-warning mb-4 text-sm"
          role="status"
        >
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>
            {gettext("%{community} needs a bit more from your profile.",
              community: @active_community.name
            )}
          </span>
          <.link
            navigate={~p"/c/#{@active_community.slug}/complete-profile"}
            class="btn btn-sm"
          >
            {gettext("Complete profile")}
          </.link>
        </div>

        <.header>
          {@active_community.name}
          <:subtitle :if={@active_community.description}>
            {@active_community.description}
          </:subtitle>
        </.header>

        <.feed_sort_form
          :if={@home_posts != []}
          current_user={@current_scope.user}
          class="flex items-center justify-end gap-1.5 pb-1 text-sm text-base-content/60"
        />

        <section :if={@home_posts != []} class="space-y-3">
          <div :for={post <- @home_posts}>
            <.post_card
              post={post}
              current_user={@current_scope.user}
              permissions={post_permissions(post, @current_scope.user)}
              group_name={post.group.name}
            />
          </div>
        </section>

        <.empty_state
          :if={@home_posts == [] and @member_groups != []}
          icon="hero-chat-bubble-left-right"
          headline={gettext("Nothing in your feed yet")}
          description={gettext("Posts from your groups appear here, newest first.")}
        />

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
      if Authorization.can?(
           socket.assigns.current_scope,
           :view_community,
           socket.assigns.active_community,
           socket.assigns.community_relationship
         ) do
        current_user = socket.assigns.current_scope.user

        if connected?(socket) do
          Enum.each(socket.assigns.member_groups, &Feed.subscribe/1)
        end

        socket
        |> assign(:public_groups, [])
        |> assign(:acknowledgment_status, nil)
        |> assign(
          :missing_required_fields,
          Communities.missing_required_custom_fields(
            socket.assigns.active_community,
            current_user
          )
        )
        |> load_home_feed(current_user)
      else
        socket
        |> assign(:home_posts, [])
        |> assign(:public_groups, Groups.list_public_groups(socket.assigns.active_community))
      end

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({Kammer.Feed, _event}, socket) do
    {:noreply, load_home_feed(socket, socket.assigns.current_scope.user)}
  end

  @impl Phoenix.LiveView
  def handle_event(event, params, socket) when event in @feed_events do
    FeedEventHandlers.handle(event, params, socket, fn socket ->
      load_home_feed(socket, socket.assigns.current_scope.user)
    end)
  end

  defp load_home_feed(socket, current_user) do
    assign(
      socket,
      :home_posts,
      Feed.list_home_feed(current_user, socket.assigns.active_community, current_user.feed_sort)
    )
  end

  defp post_permissions(post, current_user) do
    group = post.group
    relationship = Authorization.relationship(current_user, group)

    %{
      edit: false,
      soft_delete: Authorization.can_soft_delete_post?(current_user, post, group, relationship),
      hard_delete: Authorization.can_hard_delete_post?(current_user, post, group, relationship),
      pin: false,
      lock_comments: false,
      view_acknowledgments:
        Authorization.can_view_acknowledgments?(current_user, post, group, relationship),
      approve: false,
      comment: Authorization.can?(current_user, :comment_in_group, group, relationship),
      react: Authorization.can_react?(current_user, group, relationship)
    }
  end
end
