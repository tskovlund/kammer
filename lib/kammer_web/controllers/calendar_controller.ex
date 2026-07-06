defmodule KammerWeb.CalendarController do
  @moduledoc """
  ICS endpoints (SPEC §6): per-group and per-user feeds behind secret
  tokens, plus authorized single-event downloads.
  """

  use KammerWeb, :controller

  alias Kammer.Calendar.ICS
  alias Kammer.Communities
  alias Kammer.Events

  @doc "Group calendar feed by secret token."
  @spec group_feed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def group_feed(conn, %{"token" => token}) do
    case Events.events_for_group_token(strip_extension(token)) do
      nil -> send_resp(conn, 404, "Not found")
      {group, events} -> send_ics(conn, ICS.calendar(events, group.name))
    end
  end

  @doc "Merged user calendar feed by secret token."
  @spec user_feed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def user_feed(conn, %{"token" => token}) do
    case Events.events_for_user_token(strip_extension(token)) do
      nil -> send_resp(conn, 404, "Not found")
      {_user, events} -> send_ics(conn, ICS.calendar(events, "Kammer"))
    end
  end

  @doc "Single event ICS download (authorized like the event page)."
  @spec event(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def event(conn, %{"community_slug" => community_slug, "event_id" => event_id}) do
    current_user = conn.assigns.current_scope && conn.assigns.current_scope.user

    with %{} = community <- Communities.get_community_by_slug(community_slug),
         {:ok, event} <- Events.fetch_viewable_event(current_user, community, event_id) do
      send_ics(conn, ICS.single(event))
    else
      _error -> send_resp(conn, 404, "Not found")
    end
  end

  defp strip_extension(token), do: String.replace_suffix(token, ".ics", "")

  defp send_ics(conn, ics_content) do
    conn
    |> put_resp_content_type("text/calendar")
    |> put_resp_header("content-disposition", ~s(attachment; filename="kammer.ics"))
    |> send_resp(200, ics_content)
  end
end
