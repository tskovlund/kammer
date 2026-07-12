defmodule KammerWeb.Api.CalendarTest do
  @moduledoc """
  iCal subscription tokens over the API (issue #260, part of #187, SPEC
  §6). The token is the whole credential and is generated on first
  fetch; the endpoints hand back the token and a ready-to-subscribe feed
  URL. The group endpoint gates exactly as the group's own feed does —
  viewable, with the events feature on — so a dead feed is never
  tokenised and an unviewable group is a neutral 404.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

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
end
