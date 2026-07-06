defmodule KammerWeb.EventLive.Index do
  @moduledoc """
  Events tab (SPEC §6): upcoming events across the groups the member can
  see, soonest first, with past events browsable below, and the member's
  personal ICS feed link (SPEC §6: secret-token URLs).
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

  alias Kammer.Events

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
      current_tab={:events}
    >
      <.header>
        {gettext("Events")}
        <:actions>
          <.link
            :if={@member_groups != []}
            navigate={~p"/c/#{@active_community.slug}/events/new"}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="size-4" /> {gettext("New event")}
          </.link>
        </:actions>
      </.header>

      <div :if={@upcoming_events != []} class="space-y-2">
        <.event_row
          :for={event <- @upcoming_events}
          event={event}
          community_slug={@active_community.slug}
          timezone={@current_scope.user.timezone}
        />
      </div>

      <.empty_state
        :if={@upcoming_events == []}
        icon="hero-calendar-days"
        headline={gettext("No upcoming events")}
        description={gettext("Rehearsals, meetings, parties — they'll show up here.")}
      >
        <:action :if={@member_groups != []}>
          <.link navigate={~p"/c/#{@active_community.slug}/events/new"} class="btn btn-primary btn-sm">
            {gettext("New event")}
          </.link>
        </:action>
      </.empty_state>

      <details :if={@past_events != []} class="pt-4">
        <summary class="cursor-pointer text-sm font-medium text-base-content/60">
          {gettext("Past events")} ({length(@past_events)})
        </summary>
        <div class="mt-2 space-y-2 opacity-75">
          <.event_row
            :for={event <- @past_events}
            event={event}
            community_slug={@active_community.slug}
            timezone={@current_scope.user.timezone}
          />
        </div>
      </details>

      <div class="pt-8 text-sm text-base-content/60">
        <p class="flex flex-wrap items-center gap-2">
          <.icon name="hero-calendar" class="size-4" />
          {gettext("Subscribe from your calendar app:")}
          <button :if={!@ics_url} phx-click="reveal_ics" class="link">
            {gettext("show my calendar link")}
          </button>
          <code :if={@ics_url} class="select-all break-all rounded bg-base-200 px-1.5 py-0.5">
            {@ics_url}
          </code>
        </p>
      </div>
    </Layouts.app>
    """
  end

  attr :event, :map, required: true
  attr :community_slug, :string, required: true
  attr :timezone, :string, required: true

  defp event_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/c/#{@community_slug}/events/#{@event.id}"}
      class="flex items-center gap-4 rounded-box border border-base-200 p-4 hover:bg-base-200"
    >
      <div class="w-14 shrink-0 text-center">
        <p class="text-xs font-medium uppercase text-[var(--accent,#3E6B48)]">
          {Calendar.strftime(local_time(@event.starts_at, @timezone), "%b")}
        </p>
        <p class="text-xl font-semibold leading-6">
          {Calendar.strftime(local_time(@event.starts_at, @timezone), "%d")}
        </p>
      </div>
      <div class="min-w-0 flex-1">
        <p class="truncate font-medium">{@event.title}</p>
        <p class="truncate text-sm text-base-content/60">
          <%= if @event.all_day do %>
            {gettext("All day")}
          <% else %>
            {Calendar.strftime(local_time(@event.starts_at, @timezone), "%H:%M")}
          <% end %>
          · {@event.group.name}
          <span :if={@event.location_name}>· {@event.location_name}</span>
        </p>
      </div>
      <span class="shrink-0 text-sm text-base-content/50">
        {yes_count(@event)} {gettext("going")}
      </span>
    </.link>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    {:ok,
     socket
     |> assign(:upcoming_events, Events.list_upcoming_events(current_user, community))
     |> assign(:past_events, Events.list_past_events(current_user, community))
     |> assign(:ics_url, nil)}
  end

  @impl Phoenix.LiveView
  def handle_event("reveal_ics", _params, socket) do
    token = Events.ensure_user_ics_token(socket.assigns.current_scope.user)
    {:noreply, assign(socket, :ics_url, url(~p"/calendar/user/#{token <> ".ics"}"))}
  end

  defp local_time(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> datetime
    end
  end

  defp yes_count(event) do
    Enum.count(event.rsvps, fn rsvp -> rsvp.status == :yes end)
  end
end
