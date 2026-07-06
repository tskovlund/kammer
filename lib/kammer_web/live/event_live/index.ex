defmodule KammerWeb.EventLive.Index do
  @moduledoc """
  Events tab of the active community. Event creation and RSVPs arrive
  with the events build step; the tab and its designed empty state are
  part of the §21 navigation IA from the start.
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
      current_tab={:events}
    >
      <.header>{gettext("Events")}</.header>

      <.empty_state
        icon="hero-calendar-days"
        headline={gettext("No upcoming events")}
        description={gettext("Rehearsals, meetings, parties — they'll show up here.")}
      />
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end
