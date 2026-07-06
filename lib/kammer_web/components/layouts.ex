defmodule KammerWeb.Layouts do
  @moduledoc """
  Application layouts implementing the SPEC §21 navigation IA: mobile
  bottom tab bar (Home · Events · Groups · Notifications · You) and a
  desktop left sidebar with the community switcher as an avatar stack.
  The active community's accent re-tints the interface via CSS custom
  properties computed by `Kammer.Design.AccentColor`.
  """

  use KammerWeb, :html

  import KammerWeb.KammerComponents

  alias Kammer.Design.AccentColor

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app shell.

  Without an `active_community` (auth pages, landing, account settings)
  it renders a quiet centered column. With one, it renders the full §21
  chrome: sidebar (desktop), top bar with switcher (mobile), bottom tab
  bar (mobile), accent-tinted.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active_community, :map, default: nil
  attr :member_communities, :list, default: []
  attr :member_groups, :list, default: []
  attr :community_relationship, :map, default: nil
  attr :current_tab, :atom, default: nil
  attr :unread_notifications, :integer, default: 0

  slot :inner_block, required: true

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <div
      class={["min-h-dvh bg-base-100", @active_community && "community-accent"]}
      style={@active_community && AccentColor.css_variables(@active_community.accent_color)}
    >
      <%= if @active_community do %>
        <.community_shell
          flash={@flash}
          current_scope={@current_scope}
          active_community={@active_community}
          member_communities={@member_communities}
          member_groups={@member_groups}
          community_relationship={@community_relationship}
          current_tab={@current_tab}
          unread_notifications={@unread_notifications}
        >
          {render_slot(@inner_block)}
        </.community_shell>
      <% else %>
        <.plain_shell flash={@flash} current_scope={@current_scope}>
          {render_slot(@inner_block)}
        </.plain_shell>
      <% end %>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  defp plain_shell(assigns) do
    ~H"""
    <header class="navbar border-b border-base-200 px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <.link navigate={~p"/"} class="text-lg font-semibold tracking-tight">
          {Application.get_env(:kammer, :product_name, "Kammer")}
        </.link>
      </div>
      <div class="flex-none">
        <ul class="flex items-center gap-2 px-1">
          <li><.theme_toggle /></li>
          <%= if @current_scope && @current_scope.user do %>
            <li>
              <.link navigate={~p"/users/settings"} class="btn btn-ghost btn-sm">
                {@current_scope.user.display_name}
              </.link>
            </li>
            <li>
              <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost btn-sm">
                {gettext("Sign out")}
              </.link>
            </li>
          <% else %>
            <li>
              <.link navigate={~p"/users/log-in"} class="btn btn-ghost btn-sm">
                {gettext("Sign in")}
              </.link>
            </li>
          <% end %>
        </ul>
      </div>
    </header>

    <main class="px-4 py-12 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :active_community, :map, required: true
  attr :member_communities, :list, default: []
  attr :member_groups, :list, default: []
  attr :community_relationship, :map, default: nil
  attr :current_tab, :atom, default: nil
  attr :unread_notifications, :integer, default: 0
  slot :inner_block, required: true

  defp community_shell(assigns) do
    ~H"""
    <div class="flex min-h-dvh">
      <%!-- Desktop sidebar: communities (avatar stack) + community nav --%>
      <aside class="sticky top-0 hidden h-dvh w-64 shrink-0 flex-col border-r border-base-200 lg:flex">
        <div class="flex min-h-0 flex-1">
          <nav
            class="flex w-16 flex-col items-center gap-2 overflow-y-auto border-r border-base-200 py-3"
            aria-label={gettext("Communities")}
          >
            <.link
              :for={community <- @member_communities}
              navigate={~p"/c/#{community.slug}"}
              title={community.name}
            >
              <.community_avatar
                community={community}
                active={community.id == @active_community.id}
              />
            </.link>
            <.link
              navigate={~p"/communities/new"}
              class="btn btn-ghost btn-sm btn-square mt-1"
              title={gettext("New community")}
            >
              <.icon name="hero-plus" class="size-4" />
            </.link>
          </nav>

          <div class="flex min-w-0 flex-1 flex-col">
            <div class="border-b border-base-200 px-4 py-3">
              <p class="truncate font-semibold">{@active_community.name}</p>
            </div>
            <nav class="flex-1 space-y-0.5 overflow-y-auto px-2 py-3 text-sm">
              <.sidebar_link
                navigate={~p"/c/#{@active_community.slug}"}
                icon="hero-home"
                active={@current_tab == :home}
              >
                {gettext("Home")}
              </.sidebar_link>
              <.sidebar_link
                navigate={~p"/c/#{@active_community.slug}/search"}
                icon="hero-magnifying-glass"
                active={@current_tab == :search}
              >
                {gettext("Search")}
              </.sidebar_link>
              <.sidebar_link
                navigate={~p"/c/#{@active_community.slug}/events"}
                icon="hero-calendar-days"
                active={@current_tab == :events}
              >
                {gettext("Events")}
              </.sidebar_link>
              <.sidebar_link
                navigate={~p"/c/#{@active_community.slug}/groups"}
                icon="hero-user-group"
                active={@current_tab == :groups}
              >
                {gettext("Groups")}
              </.sidebar_link>
              <.sidebar_link
                navigate={~p"/c/#{@active_community.slug}/members"}
                icon="hero-users"
                active={@current_tab == :members}
              >
                {gettext("Members")}
              </.sidebar_link>
              <.sidebar_link
                navigate={~p"/c/#{@active_community.slug}/files"}
                icon="hero-folder"
                active={@current_tab == :files}
              >
                {gettext("Community files")}
              </.sidebar_link>
              <.sidebar_link
                :if={admin?(@community_relationship)}
                navigate={~p"/c/#{@active_community.slug}/moderation"}
                icon="hero-shield-exclamation"
                active={@current_tab == :moderation}
              >
                {gettext("Moderation")}
              </.sidebar_link>
              <.sidebar_link
                :if={admin?(@community_relationship)}
                navigate={~p"/c/#{@active_community.slug}/settings"}
                icon="hero-cog-6-tooth"
                active={@current_tab == :settings}
              >
                {gettext("Community settings")}
              </.sidebar_link>

              <p
                :if={@member_groups != []}
                class="px-3 pb-1 pt-4 text-xs font-medium uppercase tracking-wide text-base-content/50"
              >
                {gettext("Your groups")}
              </p>
              <.link
                :for={group <- @member_groups}
                navigate={~p"/c/#{@active_community.slug}/g/#{group.slug}"}
                class="block truncate rounded-field px-3 py-1.5 hover:bg-base-200"
              >
                {group.name}
              </.link>
            </nav>
          </div>
        </div>
      </aside>

      <div class="flex min-w-0 flex-1 flex-col">
        <%!-- Top bar --%>
        <header class="navbar sticky top-0 z-20 border-b border-base-200 bg-base-100/95 px-3 backdrop-blur sm:px-6">
          <div class="flex-1 lg:hidden">
            <.community_switcher_dropdown
              active_community={@active_community}
              member_communities={@member_communities}
            />
          </div>
          <div class="hidden flex-1 lg:block"></div>
          <div class="flex items-center gap-1">
            <.theme_toggle />
            <%= if @current_scope && @current_scope.user do %>
              <.link
                navigate={~p"/users/settings"}
                class="hidden items-center gap-2 rounded-field px-2 py-1 hover:bg-base-200 lg:flex"
              >
                <.user_avatar user={@current_scope.user} size_class="size-7" text_class="text-xs" />
                <span class="max-w-32 truncate text-sm">{@current_scope.user.display_name}</span>
              </.link>
              <.link
                href={~p"/users/log-out"}
                method="delete"
                class="btn btn-ghost btn-sm hidden lg:inline-flex"
              >
                {gettext("Sign out")}
              </.link>
            <% else %>
              <.link navigate={~p"/users/log-in"} class="btn btn-primary btn-sm">
                {gettext("Sign in")}
              </.link>
            <% end %>
          </div>
        </header>

        <main class="flex-1 px-4 pb-24 pt-6 sm:px-6 lg:px-10 lg:pb-10">
          <div class="mx-auto max-w-3xl">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <%!-- Mobile bottom tab bar (SPEC §21) --%>
    <nav
      class="dock border-t border-base-200 bg-base-100 lg:hidden"
      aria-label={gettext("Primary")}
    >
      <.tab_link
        navigate={~p"/c/#{@active_community.slug}"}
        icon="hero-home"
        active={@current_tab == :home}
        label={gettext("Home")}
      />
      <.tab_link
        navigate={~p"/c/#{@active_community.slug}/events"}
        icon="hero-calendar-days"
        active={@current_tab == :events}
        label={gettext("Events")}
      />
      <.tab_link
        navigate={~p"/c/#{@active_community.slug}/groups"}
        icon="hero-user-group"
        active={@current_tab == :groups}
        label={gettext("Groups")}
      />
      <.tab_link
        navigate={~p"/c/#{@active_community.slug}/notifications"}
        icon="hero-bell"
        active={@current_tab == :notifications}
        label={gettext("Notifications")}
        badge={@unread_notifications}
      />
      <.tab_link
        navigate={~p"/users/settings"}
        icon="hero-user-circle"
        active={@current_tab == :you}
        label={gettext("You")}
      />
    </nav>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp sidebar_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-2.5 rounded-field px-3 py-1.5 hover:bg-base-200",
        @active && "accent-soft accent-text font-medium"
      ]}
      aria-current={@active && "page"}
    >
      <.icon name={@icon} class="size-4.5 shrink-0" />
      <span class="truncate">{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :badge, :integer, default: 0

  defp tab_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class={@active && "dock-active"} aria-current={@active && "page"}>
      <span class="relative">
        <.icon name={@icon} class="size-5" />
        <span
          :if={@badge > 0}
          class="absolute -right-1.5 -top-1 size-2 rounded-full bg-[var(--accent,#3E6B48)]"
          aria-label={gettext("Unread notifications")}
        ></span>
      </span>
      <span class="dock-label">{@label}</span>
    </.link>
    """
  end

  attr :active_community, :map, required: true
  attr :member_communities, :list, default: []

  defp community_switcher_dropdown(assigns) do
    ~H"""
    <div class="dropdown">
      <button type="button" tabindex="0" class="btn btn-ghost gap-2 px-2">
        <.community_avatar
          community={@active_community}
          size_class="size-7"
          text_class="text-xs"
        />
        <span class="max-w-40 truncate font-semibold">{@active_community.name}</span>
        <.icon name="hero-chevron-down" class="size-4 opacity-60" />
      </button>
      <ul
        tabindex="0"
        class="dropdown-content menu z-30 mt-1 w-64 rounded-box border border-base-200 bg-base-100 p-2 shadow-sm"
      >
        <li :for={community <- @member_communities}>
          <.link navigate={~p"/c/#{community.slug}"} class="flex items-center gap-2">
            <.community_avatar community={community} size_class="size-7" text_class="text-xs" />
            <span class="truncate">{community.name}</span>
            <.icon
              :if={community.id == @active_community.id}
              name="hero-check"
              class="ml-auto size-4"
            />
          </.link>
        </li>
        <li class="mt-1 border-t border-base-200 pt-1">
          <.link navigate={~p"/communities/new"}>
            <.icon name="hero-plus" class="size-4" /> {gettext("New community")}
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  defp admin?(%{community_role: role}), do: role in [:owner, :admin]
  defp admin?(_relationship), do: false

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  @spec flash_group(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  @spec theme_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
