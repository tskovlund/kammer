defmodule KammerWeb.CalendarControllerTest do
  @moduledoc """
  The plain-HTTP ICS endpoints (SPEC §6): the token-authenticated group
  feed and the single-event download. These routes survive the LiveView
  removal cut (#187), so they live in a controller test rather than in
  the event-flow LiveView tests.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures

  alias Kammer.Events

  setup %{conn: conn} do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)

    {:ok, event} =
      Events.create_event(member, group, %{
        "title" => "Generalprøve",
        "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour),
        "location_name" => "Stakladen"
      })

    %{conn: log_in_user(conn, member), community: community, group: group, event: event}
  end

  test "group feed by token and single event download", %{
    conn: conn,
    community: community,
    group: group,
    event: event
  } do
    token = Events.ensure_group_ics_token(group)

    feed_conn = get(build_conn(), "/calendar/group/#{token}.ics")
    assert feed_conn.status == 200
    assert feed_conn.resp_body =~ "Generalprøve"

    event_conn = get(conn, "/c/#{community.slug}/events/#{event.id}/ics")
    assert event_conn.status == 200
    assert event_conn.resp_body =~ "BEGIN:VEVENT"

    # A bogus token answers 404 — the token is the credential.
    bogus_conn = get(build_conn(), "/calendar/group/wrong-token.ics")
    assert bogus_conn.status == 404
  end
end
