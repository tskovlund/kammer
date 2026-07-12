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
  exactly as every group-scoped endpoint does (via `fetch_viewable_group`
  — an unviewable group is the same 403 the events API gives, an absent
  one a 404), and additionally requires the `events` feature to be on:
  with it off the group's feed itself 404s (events.ex), so the token
  would be dead, and the endpoint answers that same 404 rather than mint
  one.
  """

  use KammerWeb, :controller

  alias Kammer.Communities
  alias Kammer.Events
  alias Kammer.Groups
  alias Kammer.Groups.Group
  alias KammerWeb.ApiError

  @spec me(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def me(conn, _params) do
    token = Events.ensure_user_ics_token(conn.assigns.current_scope.user)
    json(conn, %{data: %{token: token, url: url(~p"/calendar/user/#{token <> ".ics"}")}})
  end

  @spec group(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def group(conn, %{"community_slug" => community_slug, "group_slug" => group_slug}) do
    with_group(conn, community_slug, group_slug, fn group ->
      if Group.feature_enabled?(group, :events) do
        token = Events.ensure_group_ics_token(group)
        json(conn, %{data: %{token: token, url: url(~p"/calendar/group/#{token <> ".ics"}")}})
      else
        ApiError.send(conn, :not_found, "Not found.")
      end
    end)
  end

  defp with_group(conn, community_slug, group_slug, fun) do
    user = conn.assigns.current_scope.user

    with %Communities.Community{} = community <-
           Communities.get_community_by_slug(community_slug),
         {:ok, group} <- Groups.fetch_viewable_group(user, community, group_slug) do
      fun.(group)
    else
      nil -> ApiError.send(conn, :not_found, "Not found.")
      error -> ApiError.from_result(conn, error)
    end
  end
end
