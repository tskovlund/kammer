defmodule KammerWeb.InstanceLive.Home do
  @moduledoc """
  Instance landing page: signed-in users see their communities (and jump
  straight in); visitors see the product ethos and the communities that
  opted into being listed (SPEC §3: `listed_on_instance`, default off).
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

  alias Kammer.Communities

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%= if @current_scope && @current_scope.user do %>
        <.header>
          {gettext("Your communities")}
          <:subtitle :if={@my_communities != []}>
            {gettext("Pick a community to continue.")}
          </:subtitle>
        </.header>

        <div :if={@my_communities != []} class="space-y-2">
          <.link
            :for={community <- @my_communities}
            navigate={~p"/c/#{community.slug}"}
            class="flex items-center gap-3 rounded-box border border-base-200 p-4 hover:bg-base-200"
          >
            <.community_avatar community={community} size_class="size-10" />
            <div class="min-w-0">
              <p class="truncate font-medium">{community.name}</p>
              <p :if={community.description} class="truncate text-sm text-base-content/60">
                {community.description}
              </p>
            </div>
            <.icon name="hero-chevron-right" class="ml-auto size-5 text-base-content/40" />
          </.link>
        </div>

        <.empty_state
          :if={@my_communities == []}
          icon="hero-user-group"
          headline={gettext("You're not in any community yet")}
          description={
            gettext(
              "Communities are joined by invitation. Ask an organizer for an invite link — or create your own community."
            )
          }
        >
          <:action>
            <.link navigate={~p"/communities/new"} class="btn btn-primary btn-sm">
              {gettext("Create a community")}
            </.link>
          </:action>
        </.empty_state>
      <% else %>
        <div class="space-y-6 py-8 text-center">
          <h1 class="text-3xl font-semibold tracking-tight">
            {Application.get_env(:kammer, :product_name, "Kammer")}
          </h1>
          <p class="mx-auto max-w-md text-base-content/70">
            {gettext(
              "A calm, self-hosted home for real-world communities. No ads, no algorithm — just your people."
            )}
          </p>
          <div class="flex justify-center gap-3">
            <.link navigate={~p"/users/log-in"} class="btn btn-primary">
              {gettext("Sign in")}
            </.link>
            <.link navigate={~p"/users/register"} class="btn btn-ghost">
              {gettext("Create an account")}
            </.link>
          </div>
        </div>

        <div :if={@listed_communities != []} class="space-y-2 pt-6">
          <h2 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
            {gettext("Communities on this instance")}
          </h2>
          <.link
            :for={community <- @listed_communities}
            navigate={~p"/c/#{community.slug}"}
            class="flex items-center gap-3 rounded-box border border-base-200 p-4 hover:bg-base-200"
          >
            <.community_avatar community={community} size_class="size-10" />
            <div class="min-w-0">
              <p class="truncate font-medium">{community.name}</p>
              <p :if={community.description} class="truncate text-sm text-base-content/60">
                {community.description}
              </p>
            </div>
          </.link>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    my_communities =
      case socket.assigns.current_scope do
        %{user: user} when not is_nil(user) -> Communities.list_user_communities(user)
        _anonymous -> []
      end

    {:ok,
     socket
     |> assign(:my_communities, my_communities)
     |> assign(:listed_communities, Communities.list_public_communities())}
  end
end
