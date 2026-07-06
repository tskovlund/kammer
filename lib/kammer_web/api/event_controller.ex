defmodule KammerWeb.Api.EventController do
  @moduledoc """
  Events over the API (RFC 0001): listings, details, and member RSVP —
  the same context functions and authorization as the UI. Guest RSVP
  stays a web flow (it's for people without accounts, and the API
  authenticates devices).
  """

  use KammerWeb, :controller

  alias Kammer.Communities
  alias Kammer.Events
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"community_slug" => slug}) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user
      events = Events.list_upcoming_events(user, community)
      json(conn, %{data: Enum.map(events, &Serializer.event/1)})
    end)
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"community_slug" => slug, "event_id" => event_id}) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      case Events.fetch_viewable_event(user, community, event_id) do
        {:ok, event} ->
          json(conn, %{data: Serializer.event(event, Events.get_rsvp(event, user))})

        error ->
          ApiError.from_result(conn, error)
      end
    end)
  end

  @spec rsvp(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rsvp(conn, %{"community_slug" => slug, "event_id" => event_id, "status" => status})
      when status in ["yes", "no", "maybe"] do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      with {:ok, event} <- Events.fetch_viewable_event(user, community, event_id),
           {:ok, rsvp} <- Events.rsvp(user, event, String.to_existing_atom(status)) do
        json(conn, %{data: %{event_id: event.id, status: rsvp.status}})
      else
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  def rsvp(conn, _params),
    do: ApiError.send(conn, :bad_request, "status must be one of yes, no, maybe.")

  defp with_community(conn, slug, fun) do
    case Communities.get_community_by_slug(slug) do
      nil -> ApiError.send(conn, :not_found, "Not found.")
      community -> fun.(community)
    end
  end
end
