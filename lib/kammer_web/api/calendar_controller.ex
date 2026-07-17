defmodule KammerWeb.Api.CalendarController do
  @moduledoc """
  iCal subscription tokens over the API (issue #260, part of #187, SPEC
  §6). The calendar *feeds* live behind secret-token URLs served
  unauthenticated by `KammerWeb.CalendarController`; these authenticated
  endpoints hand the signed-in caller the subscription URL to paste into
  a calendar app — their own merged-events feed (`/me/calendar-token`),
  or a group's (`.../groups/:group_slug/calendar-token`). The token is
  generated on first fetch (`Events.ensure_*_ics_token/1`) and is itself
  the whole credential (SPEC §6), so each endpoint returns the token and
  the ready-to-use `…/calendar/…/<token>.ics` URL — the client just
  scheme-swaps to `webcal://` if it wants.

  Personal is owner-scoped by construction. The group endpoint gates
  exactly as every group-scoped endpoint does (`GroupGate.fetch/4`): an
  absent community, an absent group, and a group the caller may not
  even *view* all answer the same neutral 404 (#156/#161, #339) — never
  a 403 that would confirm a hidden group exists. It additionally
  requires the `events` feature to be on: with it off the group's feed
  itself 404s (events.ex), so the token would be dead, and the endpoint
  answers that same 404 rather than mint one.

  One more calendar surface lives here: the single-event ICS download
  (`:event`, issue #307) — the Bearer-authenticated twin of the browser
  `/c/:community_slug/events/:event_id/ics` route. The PWA can't attach
  its device token to a plain `<a href>` navigation, so on that route
  every members-only event 404'd for exactly the signed-in members it
  belongs to; this endpoint serves the same `ICS.single/1` bytes behind
  the API's auth. Unlike the token endpoints above it addresses an
  *event*, so it follows the events surface's no-oracle stance
  (#156/#161): an event the caller can't see answers the same 404 as one
  that doesn't exist, never a 403.
  """

  use KammerWeb, :controller

  alias Kammer.Calendar.ICS
  alias Kammer.Communities
  alias Kammer.Events
  alias KammerWeb.Api.GroupGate
  alias KammerWeb.ApiError

  @spec me(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def me(conn, _params) do
    token = Events.ensure_user_ics_token(conn.assigns.current_scope.user)
    json(conn, %{data: %{token: token, url: url(~p"/calendar/user/#{token <> ".ics"}")}})
  end

  @spec group(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def group(conn, %{"community_slug" => community_slug, "group_slug" => group_slug}) do
    with_group(conn, community_slug, group_slug, fn group ->
      token = Events.ensure_group_ics_token(group)
      json(conn, %{data: %{token: token, url: url(~p"/calendar/group/#{token <> ".ics"}")}})
    end)
  end

  @spec event(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def event(conn, %{"community_slug" => community_slug, "event_id" => event_id}) do
    user = conn.assigns.current_scope.user

    with %Communities.Community{} = community <-
           Communities.get_community_by_slug(community_slug),
         {:ok, event} <- Events.fetch_viewable_event(user, community, event_id) do
      conn
      |> put_resp_content_type("text/calendar")
      |> put_resp_header("content-disposition", ~s(attachment; filename="kammer.ics"))
      |> send_resp(200, ICS.single(event))
    else
      # Absent community, absent event, and an event the caller can't
      # see all fold into one neutral 404 (no oracle — see moduledoc).
      _error -> ApiError.send(conn, :not_found, "Not found.")
    end
  end

  # No-oracle (#156/#161, #339): a missing community, a missing group,
  # a group the caller may not even *view*, and (via `feature: :events`)
  # a group with events off all fold into the same 404 via
  # `GroupGate.fetch/4` — a dead feed is never tokenised, and an
  # unviewable group is never confirmed to exist.
  defp with_group(conn, community_slug, group_slug, fun) do
    user = conn.assigns.current_scope.user

    case GroupGate.fetch(user, community_slug, group_slug, feature: :events) do
      {:ok, _community, group} -> fun.(group)
      {:error, :not_found} -> ApiError.send(conn, :not_found, "Not found.")
    end
  end
end
