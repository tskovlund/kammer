defmodule KammerWeb.NotificationLive.Index do
  @moduledoc """
  Notification center tab. Notification delivery arrives with the
  notifications build step; the tab and its designed empty state are part
  of the §21 navigation IA from the start.
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

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
      current_tab={:notifications}
    >
      <.header>{gettext("Notifications")}</.header>

      <.empty_state
        icon="hero-bell"
        headline={gettext("You're all caught up")}
        description={gettext("Mentions, replies, and event reminders will land here.")}
      />
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end
