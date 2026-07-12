defmodule KammerWeb.Api.EventSeriesTest do
  @moduledoc """
  The recurring-series organizer view over the API (issue #260, part of
  #187, SPEC §6): a series' occurrences and its attendance matrix,
  organizer-only. The matrix/occurrence *behavior* is proven in
  `Kammer.EventsRecurrenceTest`; here we pin the wire shape and the
  transport gates — 403 for a non-manager, 404 for an absent series or a
  group with the events feature off.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Events
  alias Kammer.Groups.GroupMembership
  alias Kammer.Repo

  defp series_context do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    creator = group_member_fixture(group)
    starts_at = DateTime.add(DateTime.utc_now(:second), 24, :hour)
    until = starts_at |> DateTime.add(21, :day) |> DateTime.to_date()

    {:ok, [first | _] = occurrences} =
      Events.create_recurring_event(
        creator,
        group,
        %{"title" => "Choir practice", "starts_at" => starts_at},
        %{"frequency" => "weekly", "until" => Date.to_iso8601(until)}
      )

    %{
      community: community,
      group: group,
      creator: creator,
      series: Events.get_series(first),
      occurrences: occurrences,
      first: first
    }
  end

  describe "GET /communities/:community_slug/events/series/:series_id" do
    setup do: series_context()

    test "the organizer gets the series, its occurrences, and the attendance matrix", %{
      community: community,
      creator: creator,
      series: series,
      occurrences: occurrences,
      first: first
    } do
      {:ok, _} = Events.rsvp(creator, first, :yes)

      data =
        creator
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/events/series/#{series.id}")
        |> tap(&assert_operation_response(&1, "events_series"))
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["series"]["id"] == series.id
      assert data["series"]["frequency"] == "weekly"

      # Every occurrence, soonest first, each carrying its own computed
      # rsvp_counts and cancel state.
      assert length(data["occurrences"]) == length(occurrences)
      first_occurrence = hd(data["occurrences"])
      assert first_occurrence["id"] == first.id
      assert first_occurrence["cancelled"] == false
      assert first_occurrence["rsvp_counts"]["yes"] == 1

      # The matrix: the creator is a member row, and their :yes on `first`
      # shows at the column index aligned to attendance.occurrences.
      attendance = data["attendance"]
      column = Enum.find_index(attendance["occurrences"], &(&1["id"] == first.id))
      creator_row = Enum.find(attendance["rows"], &(&1["member"]["id"] == creator.id))
      assert Enum.at(creator_row["statuses"], column) == "yes"
      # An un-answered occurrence serializes as a null cell, not a gap.
      assert Enum.any?(creator_row["statuses"], &is_nil/1)
    end

    test "a caller who cannot view the group gets 404, never a 403 confirm-oracle", %{
      community: community
    } do
      # A private group's series must be invisible to a community member who
      # is not in the group: its occurrences 404 for them, so the series does
      # too — a 403 here would confirm the series exists (no-oracle, #156/#161).
      private = group_fixture(community, %{visibility: :private})
      creator = group_member_fixture(private)
      starts_at = DateTime.add(DateTime.utc_now(:second), 24, :hour)
      until = starts_at |> DateTime.add(14, :day) |> DateTime.to_date()

      {:ok, [first | _]} =
        Events.create_recurring_event(
          creator,
          private,
          %{"title" => "Rehearsal", "starts_at" => starts_at},
          %{"frequency" => "weekly", "until" => Date.to_iso8601(until)}
        )

      series = Events.get_series(first)
      outsider = member_fixture(community)

      outsider
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/events/series/#{series.id}")
      |> json_response(404)
    end

    test "a former creator who has left a private group gets 404, not a 500", %{
      community: community
    } do
      # The creator still passes the manage gate (creator? is a bare id
      # match) but can no longer view the private group, so the series must
      # 404 — and must not raise where attendance_matrix lists members.
      private = group_fixture(community, %{visibility: :private})
      creator = group_member_fixture(private)
      starts_at = DateTime.add(DateTime.utc_now(:second), 24, :hour)
      until = starts_at |> DateTime.add(14, :day) |> DateTime.to_date()

      {:ok, [first | _]} =
        Events.create_recurring_event(
          creator,
          private,
          %{"title" => "Rehearsal", "starts_at" => starts_at},
          %{"frequency" => "weekly", "until" => Date.to_iso8601(until)}
        )

      series = Events.get_series(first)
      GroupMembership |> Repo.get_by!(user_id: creator.id, group_id: private.id) |> Repo.delete!()

      creator
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/events/series/#{series.id}")
      |> json_response(404)
    end

    test "a member who does not manage the series is forbidden", %{
      community: community,
      group: group,
      series: series
    } do
      outsider = group_member_fixture(group)

      outsider
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/events/series/#{series.id}")
      |> json_response(403)
    end

    test "an absent series is a neutral 404", %{community: community, creator: creator} do
      creator
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/events/series/#{Ecto.UUID.generate()}")
      |> json_response(404)
    end

    test "a series whose group has the events feature off is a 404", %{
      community: community,
      group: group,
      creator: creator,
      series: series
    } do
      group |> Ecto.Changeset.change(features: [:feed]) |> Repo.update!()

      creator
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/events/series/#{series.id}")
      |> json_response(404)
    end
  end
end
