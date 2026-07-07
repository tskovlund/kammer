defmodule Kammer.Events.RecurrenceTest do
  @moduledoc """
  Pure date math for "constrained RRULE" series (SPEC §6) — no
  database, no Repo, just the step patterns weekly/biweekly/monthly
  actually need.
  """

  use ExUnit.Case, async: true

  alias Kammer.Events.Recurrence

  describe "occurrence_starts/4" do
    test "weekly steps by 7 days" do
      starts_at = ~U[2026-01-06 19:00:00Z]
      until = ~D[2026-01-27]

      assert Recurrence.occurrence_starts(starts_at, :weekly, until, "Etc/UTC") == [
               ~U[2026-01-06 19:00:00Z],
               ~U[2026-01-13 19:00:00Z],
               ~U[2026-01-20 19:00:00Z],
               ~U[2026-01-27 19:00:00Z]
             ]
    end

    test "biweekly steps by 14 days" do
      starts_at = ~U[2026-01-06 19:00:00Z]
      until = ~D[2026-02-10]

      assert Recurrence.occurrence_starts(starts_at, :biweekly, until, "Etc/UTC") == [
               ~U[2026-01-06 19:00:00Z],
               ~U[2026-01-20 19:00:00Z],
               ~U[2026-02-03 19:00:00Z]
             ]
    end

    test "monthly keeps the day of month" do
      starts_at = ~U[2026-01-15 19:00:00Z]
      until = ~D[2026-04-01]

      assert Recurrence.occurrence_starts(starts_at, :monthly, until, "Etc/UTC") == [
               ~U[2026-01-15 19:00:00Z],
               ~U[2026-02-15 19:00:00Z],
               ~U[2026-03-15 19:00:00Z]
             ]
    end

    test "monthly clamps to the shortest month instead of overflowing" do
      starts_at = ~U[2026-01-31 12:00:00Z]
      until = ~D[2026-04-30]

      # Jan 31 → Feb (28 days, 2026 is not a leap year) → Mar 31 → Apr 30
      assert Recurrence.occurrence_starts(starts_at, :monthly, until, "Etc/UTC") == [
               ~U[2026-01-31 12:00:00Z],
               ~U[2026-02-28 12:00:00Z],
               ~U[2026-03-31 12:00:00Z],
               ~U[2026-04-30 12:00:00Z]
             ]
    end

    test "the until bound is inclusive by calendar date, in the series timezone" do
      # 19:00 Europe/Copenhagen on Jan 20 is still Jan 20 there, even
      # though it's already after midnight UTC on Jan 21.
      starts_at = DateTime.new!(~D[2026-01-06], ~T[19:00:00], "Europe/Copenhagen")
      until = ~D[2026-01-20]

      dates =
        Recurrence.occurrence_starts(starts_at, :weekly, until, "Europe/Copenhagen")
        |> Enum.map(&DateTime.shift_zone!(&1, "Europe/Copenhagen"))
        |> Enum.map(&DateTime.to_date/1)

      assert dates == [~D[2026-01-06], ~D[2026-01-13], ~D[2026-01-20]]
    end

    test "an until before the first occurrence yields nothing" do
      starts_at = ~U[2026-06-01 12:00:00Z]
      until = ~D[2026-05-01]

      assert Recurrence.occurrence_starts(starts_at, :weekly, until, "Etc/UTC") == []
    end

    test "is capped at max_occurrences even with a far-future until" do
      starts_at = ~U[2026-01-01 12:00:00Z]
      until = ~D[2036-01-01]

      occurrences = Recurrence.occurrence_starts(starts_at, :weekly, until, "Etc/UTC")
      assert length(occurrences) == Recurrence.max_occurrences()
    end
  end
end
