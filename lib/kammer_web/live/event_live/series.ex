defmodule KammerWeb.EventLive.Series do
  @moduledoc """
  A recurring series' organizer view (SPEC §6): every occurrence with
  cancel/uncancel, and the attendance matrix (members × upcoming
  instances). Restricted to whoever manages the series — its creator
  or a group moderator.
  """

  use KammerWeb, :live_view

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
        {gettext("Recurring series")}
        <:subtitle>{series_description(@series)}</:subtitle>
      </.header>

      <section class="space-y-2">
        <h2 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Occurrences")}
        </h2>
        <div
          :for={occurrence <- @occurrences}
          class="flex items-center justify-between gap-4 rounded-box border border-base-200 p-3"
        >
          <div class="min-w-0">
            <.link
              navigate={~p"/c/#{@active_community.slug}/events/#{occurrence.id}"}
              class={["font-medium link", occurrence.cancelled_at && "line-through opacity-60"]}
            >
              {Calendar.strftime(occurrence.starts_at, "%d %b %Y %H:%M UTC")}
            </.link>
            <p class="text-sm text-base-content/60">
              <%= if occurrence.cancelled_at do %>
                {gettext("Cancelled")}
              <% else %>
                {gettext("%{yes} going · %{maybe} maybe",
                  yes: rsvp_count(occurrence, :yes),
                  maybe: rsvp_count(occurrence, :maybe)
                )}
              <% end %>
            </p>
          </div>
          <.button
            :if={!occurrence.cancelled_at}
            phx-click="cancel_occurrence"
            phx-value-id={occurrence.id}
            data-confirm={gettext("Cancel this occurrence?")}
            class="btn btn-outline btn-sm"
          >
            {gettext("Cancel")}
          </.button>
          <.button
            :if={occurrence.cancelled_at}
            phx-click="uncancel_occurrence"
            phx-value-id={occurrence.id}
            class="btn btn-outline btn-sm"
          >
            {gettext("Restore")}
          </.button>
        </div>
      </section>

      <section class="space-y-2 pt-6">
        <h2 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Attendance matrix")}
        </h2>

        <div :if={@matrix.occurrences == []} class="text-sm text-base-content/60">
          {gettext("No upcoming occurrences.")}
        </div>

        <div :if={@matrix.occurrences != []} class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("Member")}</th>
                <th :for={occurrence <- @matrix.occurrences} class="text-center whitespace-nowrap">
                  {Calendar.strftime(occurrence.starts_at, "%d %b")}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @matrix.rows}>
                <td class="whitespace-nowrap">{row.member.display_name}</td>
                <td :for={occurrence <- @matrix.occurrences} class="text-center">
                  {status_glyph(row.statuses[occurrence.id])}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"series_id" => series_id}, _session, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    case Events.fetch_manageable_series(current_user, community, series_id) do
      {:ok, series} ->
        {:ok, socket |> assign(:series, series) |> reload()}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Series not found."))
         |> push_navigate(to: ~p"/c/#{community.slug}/events")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("cancel_occurrence", %{"id" => occurrence_id}, socket) do
    with %Kammer.Events.Event{} = occurrence <- find_occurrence(socket, occurrence_id),
         {:ok, _cancelled} <-
           Events.cancel_occurrence(socket.assigns.current_scope.user, occurrence) do
      {:noreply, reload(socket)}
    else
      _error -> {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("uncancel_occurrence", %{"id" => occurrence_id}, socket) do
    with %Kammer.Events.Event{} = occurrence <- find_occurrence(socket, occurrence_id),
         {:ok, _restored} <-
           Events.uncancel_occurrence(socket.assigns.current_scope.user, occurrence) do
      {:noreply, reload(socket)}
    else
      _error -> {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  defp find_occurrence(socket, occurrence_id) do
    Enum.find(socket.assigns.occurrences, &(&1.id == occurrence_id))
  end

  defp reload(socket) do
    current_user = socket.assigns.current_scope.user
    series = socket.assigns.series

    {:ok, matrix} = Events.attendance_matrix(current_user, series)

    socket
    |> assign(:occurrences, Events.list_series_occurrences(series))
    |> assign(:matrix, matrix)
  end

  defp rsvp_count(occurrence, status) do
    Enum.count(occurrence.rsvps, &(&1.status == status))
  end

  defp status_glyph(:yes), do: "✅"
  defp status_glyph(:maybe), do: "❔"
  defp status_glyph(:no), do: "❌"
  defp status_glyph(nil), do: "—"

  defp series_description(series) do
    frequency =
      case series.frequency do
        :weekly -> gettext("Weekly")
        :biweekly -> gettext("Every two weeks")
        :monthly -> gettext("Monthly")
      end

    gettext("%{frequency}, until %{until}",
      frequency: frequency,
      until: Calendar.strftime(series.until, "%d %b %Y")
    )
  end
end
