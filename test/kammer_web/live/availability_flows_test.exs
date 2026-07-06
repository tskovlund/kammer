defmodule KammerWeb.AvailabilityFlowsTest do
  @moduledoc """
  Date-finding end to end (issue #39): create a poll from the group
  page, answer on the grid, convert the winner into an event.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Availability
  alias Kammer.Events.Event
  alias Kammer.Groups.Group
  alias Kammer.Repo

  defp availability_context(_context) do
    {community, _owner} = community_with_owner_fixture()

    group =
      community
      |> group_fixture()
      |> Group.features_changeset(%{"features" => ["feed", "events", "availability"]})
      |> Repo.update!()
      |> Map.put(:community, community)

    creator = group_member_fixture(group)
    member = group_member_fixture(group)

    %{community: community, group: group, creator: creator, member: member}
  end

  describe "the date-finding journey" do
    setup :availability_context

    test "create → answer → convert", %{
      community: community,
      group: group,
      creator: creator,
      member: member
    } do
      creator_conn = log_in_user(build_conn(), creator)

      {:ok, new_lv, _html} =
        live(creator_conn, ~p"/c/#{community.slug}/g/#{group.slug}/availability/new")

      tomorrow =
        DateTime.utc_now()
        |> DateTime.add(24, :hour)
        |> Calendar.strftime("%Y-%m-%dT%H:%M")

      day_after =
        DateTime.utc_now()
        |> DateTime.add(48, :hour)
        |> Calendar.strftime("%Y-%m-%dT%H:%M")

      {:ok, poll_lv, _html} =
        new_lv
        |> form("#availability-form",
          poll: %{title: "Generalforsamling", options: %{"0" => tomorrow, "1" => day_after}}
        )
        |> render_submit()
        |> follow_redirect(creator_conn)

      [poll] = Repo.all(Kammer.Availability.AvailabilityPoll)
      assert poll.title == "Generalforsamling"
      {:ok, loaded, _group} = Availability.fetch_viewable_poll(creator, poll.id)
      [first_option, _second] = loaded.options

      # A member answers on the grid.
      member_conn = log_in_user(build_conn(), member)

      {:ok, member_lv, member_html} =
        live(member_conn, ~p"/c/#{community.slug}/availability/#{poll.id}")

      assert member_html =~ "Generalforsamling"

      member_lv |> element("#answer-#{first_option.id}-yes") |> render_click()

      {:ok, reloaded, _group} = Availability.fetch_viewable_poll(member, poll.id)
      [answered, _other] = reloaded.options
      assert [response] = answered.responses
      assert response.answer == :yes

      # The creator picks the winning date — event created, poll closed.
      poll_lv |> element("#convert-#{first_option.id}") |> render_click()

      assert [event] = Repo.all(Event)
      assert event.title == "Generalforsamling"
      assert event.starts_at == first_option.starts_at
      assert Repo.get!(Kammer.Availability.AvailabilityPoll, poll.id).closed_at
    end

    test "the events page lists open polls; gated-off groups show nothing", %{
      community: community,
      group: group,
      creator: creator
    } do
      {:ok, _poll} =
        Availability.create_poll(creator, group, %{"title" => "Sommerfest?"}, [
          DateTime.add(DateTime.utc_now(:second), 24, :hour)
        ])

      conn = log_in_user(build_conn(), creator)
      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}/events")
      assert html =~ "Sommerfest?"

      {:ok, _group} =
        group |> Group.features_changeset(%{"features" => ["feed", "events"]}) |> Repo.update()

      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}/events")
      refute html =~ "Sommerfest?"
    end
  end
end
