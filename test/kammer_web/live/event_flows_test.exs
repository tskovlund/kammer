defmodule KammerWeb.EventFlowsTest do
  @moduledoc """
  LiveView tests for the event flows (SPEC §17: RSVP is a critical flow).
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Events

  defp event_context(%{conn: conn}) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)

    {:ok, event} =
      Events.create_event(member, group, %{
        "title" => "Generalprøve",
        "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour),
        "location_name" => "Stakladen"
      })

    %{
      conn: log_in_user(conn, member),
      community: community,
      group: group,
      member: member,
      event: event
    }
  end

  describe "events index" do
    setup :event_context

    test "lists upcoming events", %{conn: conn, community: community} do
      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}/events")
      assert html =~ "Generalprøve"
      assert html =~ "Stakladen"
    end

    test "reveals the personal ICS link", %{conn: conn, community: community} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/events")
      html = lv |> element("button", "show my calendar link") |> render_click()
      assert html =~ "/calendar/user/"
    end
  end

  describe "event page" do
    setup :event_context

    test "member RSVPs yes and appears in the going list", %{
      conn: conn,
      community: community,
      event: event,
      member: member
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/events/#{event.id}")

      html = lv |> element("button", "I'm going") |> render_click()

      assert html =~ "going"
      assert Events.get_rsvp(event, member).status == :yes
    end

    test "member comments on the event", %{conn: conn, community: community, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/events/#{event.id}")

      html = render_submit(lv, "create_comment", %{"body_markdown" => "Husk noderne!"})

      assert html =~ "Husk noderne!"
    end

    test "outsiders to a private group cannot open its event", %{community: community} do
      private_group = group_fixture(community, visibility: :private)
      private_member = group_member_fixture(private_group)

      {:ok, secret_event} =
        Events.create_event(private_member, private_group, %{
          "title" => "Hemmelig",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
        })

      other_member = member_fixture(community)

      assert {:error, {:live_redirect, %{to: destination}}} =
               build_conn()
               |> log_in_user(other_member)
               |> live(~p"/c/#{community.slug}/events/#{secret_event.id}")

      assert destination == "/c/#{community.slug}/events"
    end
  end

  describe "event creation flow" do
    setup :event_context

    test "member creates an event through the form", %{conn: conn, community: community} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/events/new")

      result =
        lv
        |> form("#event_form", %{
          "event" => %{
            "title" => "Sommerfest",
            "starts_on" => "2026-08-15",
            "starts_time" => "18:00",
            "all_day" => "false"
          }
        })
        |> render_submit()

      {path, _flash} = assert_redirect(lv)
      assert path =~ "/events/"
      assert result
    end

    test "member creates a recurring series through the form", %{conn: conn, community: community} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/events/new")

      html =
        lv
        |> element(~s(select[name="event[repeats]"]))
        |> render_change(%{"event" => %{"repeats" => "weekly"}})

      assert html =~ "Repeats until"

      lv
      |> form("#event_form", %{
        "event" => %{
          "title" => "Kor",
          "starts_on" => "2026-08-01",
          "starts_time" => "19:00",
          "all_day" => "false",
          "repeats" => "weekly",
          "repeat_until" => "2026-08-22"
        }
      })
      |> render_submit()

      {path, _flash} = assert_redirect(lv)
      assert path =~ "/events/series/"
    end
  end

  describe "recurring series page" do
    setup :event_context

    setup %{group: group, member: member} do
      starts_at = DateTime.new!(~D[2026-08-01], ~T[19:00:00], "Etc/UTC")

      {:ok, occurrences} =
        Events.create_recurring_event(
          member,
          group,
          %{"title" => "Kor", "starts_at" => starts_at},
          %{"frequency" => "weekly", "until" => "2026-08-22"}
        )

      series = Events.get_series(hd(occurrences))
      %{occurrences: occurrences, series: series}
    end

    test "lists occurrences and lets an organizer cancel one", %{
      conn: conn,
      community: community,
      series: series,
      occurrences: [first | _rest]
    } do
      {:ok, lv, html} = live(conn, ~p"/c/#{community.slug}/events/series/#{series.id}")
      assert html =~ "Weekly"
      assert html =~ "Attendance matrix"

      html =
        lv
        |> element(~s(button[phx-value-id="#{first.id}"]), "Cancel")
        |> render_click()

      assert html =~ "Cancelled"
      assert Kammer.Repo.get!(Kammer.Events.Event, first.id).cancelled_at
    end

    test "outsiders cannot open the series page", %{community: community, series: series} do
      outsider = member_fixture(community)

      assert {:error, {:live_redirect, %{to: destination}}} =
               build_conn()
               |> log_in_user(outsider)
               |> live(~p"/c/#{community.slug}/events/series/#{series.id}")

      assert destination == "/c/#{community.slug}/events"
    end

    test "an occurrence's own page links back to the series and shows cancellation", %{
      conn: conn,
      community: community,
      member: member,
      occurrences: [first | _rest]
    } do
      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}/events/#{first.id}")
      assert html =~ "Part of a recurring series"

      {:ok, _cancelled} = Events.cancel_occurrence(member, first)
      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}/events/#{first.id}")
      assert html =~ "This occurrence was cancelled"
    end
  end

  describe "ICS endpoints" do
    setup :event_context

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

      # Unauthorized users get a 404 on the single event of a private group.
      bogus_conn = get(build_conn(), "/calendar/group/wrong-token.ics")
      assert bogus_conn.status == 404
    end
  end
end
