defmodule KammerWeb.Api.CalendarTest do
  @moduledoc """
  iCal subscription tokens over the API (issue #260, part of #187, SPEC
  §6). The token is the whole credential and is generated on first
  fetch; the endpoints hand back the token and a ready-to-subscribe feed
  URL. The group endpoint gates exactly as the group's own feed does —
  viewable, with the events feature on — so a dead feed is never
  tokenised: an absent community or group is a 404, an existing-but-
  unviewable group the same 403 the rest of the group-scoped surface
  gives, and a group with events off a 404 (its feed 404s too).

  Also the single-event ICS download (issue #307): Bearer-authenticated,
  so "add to calendar" works for members-only events the tokenless
  browser route 404s — and, addressing an event, it follows the events
  surface's no-oracle 404 rather than the group endpoints' 403.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Events
  alias Kammer.Repo

  describe "GET /me/calendar-token" do
    test "returns the caller's feed URL and lazily mints a stable token" do
      user = user_fixture()
      refute user.ics_token

      data =
        user
        |> api_conn()
        |> get(~p"/api/v1/me/calendar-token")
        |> tap(&assert_operation_response(&1, "me_calendar_token"))
        |> json_response(200)
        |> Map.fetch!("data")

      # The token is the user's real feed credential (minted on this first
      # call), and the URL is the ready-to-paste .ics feed.
      assert data["token"] == Repo.reload!(user).ics_token
      assert String.ends_with?(data["url"], "/calendar/user/#{data["token"]}.ics")

      # A second call is idempotent — same token, not a fresh one.
      second =
        user |> api_conn() |> get(~p"/api/v1/me/calendar-token") |> json_response(200)

      assert second["data"]["token"] == data["token"]
    end
  end

  describe "GET /communities/:slug/groups/:slug/calendar-token" do
    test "a member of a viewable, events-on group gets the group feed URL" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      member = member_fixture(community)

      data =
        member
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/calendar-token")
        |> tap(&assert_operation_response(&1, "groups_calendar_token"))
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["token"] == Repo.reload!(group).ics_token
      assert String.ends_with?(data["url"], "/calendar/group/#{data["token"]}.ics")
    end

    test "a group with the events feature off is a neutral 404 — no token for a dead feed" do
      {community, _owner} = community_with_owner_fixture()

      group =
        community |> group_fixture() |> Ecto.Changeset.change(features: [:feed]) |> Repo.update!()

      member = member_fixture(community)

      member
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/calendar-token")
      |> json_response(404)

      # And nothing was minted for it.
      refute Repo.reload!(group).ics_token
    end

    test "an unknown community is a neutral 404" do
      user = user_fixture()

      user
      |> api_conn()
      |> get(~p"/api/v1/communities/no-such-community/groups/whatever/calendar-token")
      |> json_response(404)
    end

    test "an unknown group in a real community is a neutral 404" do
      {community, _owner} = community_with_owner_fixture()
      member = member_fixture(community)

      member
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/groups/no-such-group/calendar-token")
      |> json_response(404)
    end

    test "a group the caller cannot view is forbidden — the same 403 every group endpoint gives" do
      {community, _owner} = community_with_owner_fixture()
      private = group_fixture(community, %{visibility: :private})
      # A community member who is not in the private group can't view it —
      # `fetch_viewable_group` answers :unauthorized (403), consistent with
      # the events API and the rest of the group-scoped surface.
      outsider = member_fixture(community)

      outsider
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/groups/#{private.slug}/calendar-token")
      |> json_response(403)
    end
  end

  describe "GET /communities/:slug/events/:id/ics" do
    # The #307 scenario: a private group's event is invisible to the
    # tokenless browser ICS route, so its members could never "add to
    # calendar" — this Bearer-authenticated download is the fix.
    defp private_event do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, %{visibility: :private})
      insider = group_member_fixture(group)

      {:ok, event} =
        Events.create_event(insider, group, %{
          "title" => "Generalprøve",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
        })

      %{community: community, insider: insider, event: event}
    end

    test "a member of a members-only group downloads the event as an ICS attachment" do
      %{community: community, insider: insider, event: event} = private_event()

      conn =
        insider
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/events/#{event.id}/ics")

      assert response_content_type(conn, :ics)

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="kammer.ics")
             ]

      assert response(conn, 200) =~ "SUMMARY:Generalprøve"
    end

    test "an event the caller cannot see 404s like an absent one — no oracle" do
      %{community: community, event: event} = private_event()
      outsider = member_fixture(community)
      conn = api_conn(outsider)

      conn
      |> get(~p"/api/v1/communities/#{community.slug}/events/#{event.id}/ics")
      |> json_response(404)

      conn
      |> get(~p"/api/v1/communities/#{community.slug}/events/#{Ecto.UUID.generate()}/ics")
      |> json_response(404)
    end

    test "anonymous is 401 — the whole point is that this route authenticates" do
      %{community: community, event: event} = private_event()

      build_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/events/#{event.id}/ics")
      |> json_response(401)
    end
  end
end
