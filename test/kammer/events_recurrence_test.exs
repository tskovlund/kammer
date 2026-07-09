defmodule Kammer.EventsRecurrenceTest do
  @moduledoc """
  Recurring event series (SPEC §6): materialization into real `Event`
  rows, per-instance cancel, and the organizer attendance matrix.
  """

  use Kammer.DataCase, async: true
  use Oban.Testing, repo: Kammer.Repo

  import Kammer.CommunitiesFixtures

  alias Kammer.Events

  defp event_context do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    group_owner = group_member_fixture(group, :owner)
    member = group_member_fixture(group)
    %{community: community, group: group, group_owner: group_owner, member: member}
  end

  defp future(hours), do: DateTime.add(DateTime.utc_now(:second), hours, :hour)

  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end

  describe "create_recurring_event/4" do
    setup do
      event_context()
    end

    test "materializes one Event per occurrence, sharing a series_id", %{
      group: group,
      member: member
    } do
      starts_at = future(48)
      until = starts_at |> DateTime.add(21, :day) |> DateTime.to_date()

      assert {:ok, events} =
               Events.create_recurring_event(
                 member,
                 group,
                 %{"title" => "Choir practice", "starts_at" => starts_at},
                 %{"frequency" => "weekly", "until" => Date.to_iso8601(until)}
               )

      assert length(events) == 4
      assert Enum.all?(events, &(&1.title == "Choir practice"))
      assert Enum.all?(events, &(&1.series_id == hd(events).series_id))

      starts = Enum.map(events, & &1.starts_at)
      assert starts == Enum.sort(starts, DateTime)

      series = Events.get_series(hd(events))
      assert series.frequency == :weekly
      assert Events.list_series_occurrences(series) |> length() == 4

      for event <- events do
        assert_enqueued(
          worker: Kammer.Workers.EventReminderWorker,
          args: %{"event_id" => event.id}
        )
      end
    end

    test "preserves the duration for events with an end time", %{group: group, member: member} do
      starts_at = future(24)
      ends_at = DateTime.add(starts_at, 2, :hour)
      until = starts_at |> DateTime.add(14, :day) |> DateTime.to_date()

      assert {:ok, events} =
               Events.create_recurring_event(
                 member,
                 group,
                 %{"title" => "Board meeting", "starts_at" => starts_at, "ends_at" => ends_at},
                 %{"frequency" => "biweekly", "until" => Date.to_iso8601(until)}
               )

      assert Enum.all?(events, fn event ->
               DateTime.diff(event.ends_at, event.starts_at, :hour) == 2
             end)
    end

    test "follows the group's posting policy", %{community: community} do
      announcement_group = group_fixture(community, posting_policy: :admins_only)
      plain_member = group_member_fixture(announcement_group)
      starts_at = future(24)
      until = starts_at |> DateTime.add(14, :day) |> DateTime.to_date()

      assert {:error, :unauthorized} =
               Events.create_recurring_event(
                 plain_member,
                 announcement_group,
                 %{"title" => "Notice", "starts_at" => starts_at},
                 %{"frequency" => "weekly", "until" => Date.to_iso8601(until)}
               )
    end

    test "an invalid base event returns its changeset", %{group: group, member: member} do
      starts_at = future(24)
      until = starts_at |> DateTime.add(14, :day) |> DateTime.to_date()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Events.create_recurring_event(
                 member,
                 group,
                 %{"title" => "", "starts_at" => starts_at},
                 %{"frequency" => "weekly", "until" => Date.to_iso8601(until)}
               )

      assert "can't be blank" in errors_on(changeset).title
    end

    test "an until before the start produces no occurrences and errors", %{
      group: group,
      member: member
    } do
      starts_at = future(24)
      until = starts_at |> DateTime.add(-1, :day) |> DateTime.to_date()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Events.create_recurring_event(
                 member,
                 group,
                 %{"title" => "Too late", "starts_at" => starts_at},
                 %{"frequency" => "weekly", "until" => Date.to_iso8601(until)}
               )

      assert errors_on(changeset).until
    end
  end

  describe "cancel_occurrence/2 and uncancel_occurrence/2" do
    setup do
      context = event_context()
      starts_at = future(24)
      until = starts_at |> DateTime.add(21, :day) |> DateTime.to_date()

      {:ok, events} =
        Events.create_recurring_event(
          context.member,
          context.group,
          %{"title" => "Book club", "starts_at" => starts_at},
          %{"frequency" => "weekly", "until" => Date.to_iso8601(until)}
        )

      Map.put(context, :occurrences, events)
    end

    test "cancelling excludes the occurrence from upcoming listings and ICS feeds", %{
      community: community,
      group: group,
      member: member,
      occurrences: [first | _rest]
    } do
      assert {:ok, cancelled} = Events.cancel_occurrence(member, first)
      assert cancelled.cancelled_at

      upcoming = Events.list_upcoming_events(member, community)
      refute Enum.any?(upcoming, &(&1.id == first.id))

      token = Events.ensure_group_ics_token(group)
      {fetched_group, feed_events} = Events.events_for_group_token(token)
      assert fetched_group.id == group.id
      refute Enum.any?(feed_events, &(&1.id == first.id))
    end

    test "only the creator or a moderator may cancel", %{
      group: group,
      occurrences: [first | _rest]
    } do
      # The realistic attacker is a fellow group member, not a stranger.
      fellow_member = group_member_fixture(group)
      assert {:error, :unauthorized} = Events.cancel_occurrence(fellow_member, first)
    end

    test "uncancelling restores it", %{member: member, occurrences: [first | _rest]} do
      {:ok, cancelled} = Events.cancel_occurrence(member, first)
      assert {:ok, restored} = Events.uncancel_occurrence(member, cancelled)
      refute restored.cancelled_at
    end

    test "the reminder worker skips a cancelled occurrence", %{
      member: member,
      occurrences: [first | _rest]
    } do
      {:ok, _rsvp} = Events.rsvp(member, first, :yes)
      {:ok, cancelled} = Events.cancel_occurrence(member, first)
      drain_delivered_emails()

      assert :ok =
               perform_job(Kammer.Workers.EventReminderWorker, %{
                 "event_id" => cancelled.id,
                 "starts_at" => DateTime.to_iso8601(cancelled.starts_at)
               })

      import Swoosh.TestAssertions
      refute_email_sent()
    end
  end

  describe "attendance_matrix/2" do
    setup do
      context = event_context()
      starts_at = future(24)
      until = starts_at |> DateTime.add(21, :day) |> DateTime.to_date()

      {:ok, events} =
        Events.create_recurring_event(
          context.member,
          context.group,
          %{"title" => "Practice", "starts_at" => starts_at},
          %{"frequency" => "weekly", "until" => Date.to_iso8601(until)}
        )

      Map.put(context, :occurrences, events)
    end

    test "rows are group members, columns are upcoming occurrences", %{
      group_owner: group_owner,
      member: member,
      occurrences: [first, second | _rest]
    } do
      {:ok, _rsvp} = Events.rsvp(member, first, :yes)
      {:ok, _rsvp} = Events.rsvp(member, second, :no)

      assert {:ok, matrix} = Events.attendance_matrix(member, Events.get_series(first))

      assert length(matrix.occurrences) == 4
      assert length(matrix.rows) == 2

      member_row = Enum.find(matrix.rows, &(&1.member.id == member.id))
      assert member_row.statuses[first.id] == :yes
      assert member_row.statuses[second.id] == :no

      owner_row = Enum.find(matrix.rows, &(&1.member.id == group_owner.id))
      assert owner_row.statuses[first.id] == nil
    end

    test "cancelled and past occurrences are excluded from the matrix columns", %{
      member: member,
      occurrences: [first | rest]
    } do
      {:ok, _cancelled} = Events.cancel_occurrence(member, first)

      assert {:ok, matrix} = Events.attendance_matrix(member, Events.get_series(first))
      occurrence_ids = Enum.map(matrix.occurrences, & &1.id)

      refute first.id in occurrence_ids
      assert Enum.all?(rest, &(&1.id in occurrence_ids))
    end

    test "plain members cannot view the matrix", %{
      group: group,
      occurrences: [first | _rest]
    } do
      outsider_member = group_member_fixture(group)

      assert {:error, :unauthorized} =
               Events.attendance_matrix(outsider_member, Events.get_series(first))
    end
  end

  test "get_series/1 returns nil for a standalone event" do
    %{group: group, member: member} = event_context()

    {:ok, event} =
      Events.create_event(member, group, %{"title" => "Solo", "starts_at" => future(24)})

    assert Events.get_series(event) == nil
  end
end
