defmodule Kammer.Events.Recurrence do
  @moduledoc """
  Pure date math for "constrained RRULE" series (SPEC §6): weekly,
  biweekly, or monthly, bounded by an end date. Deliberately not a
  general RRULE implementation — there is no freeform editor, so this
  only needs to generate the handful of step patterns the product
  actually offers, not parse arbitrary recurrence rules.

  Arithmetic happens in the series' own timezone so wall-clock time
  (e.g. "7pm every Tuesday") survives DST transitions; only the
  returned datetimes are UTC, matching how `Event.starts_at` is
  stored.
  """

  @max_occurrences 52

  @doc "The occurrence cap (the 'constrained' in constrained RRULE)."
  @spec max_occurrences() :: pos_integer()
  def max_occurrences, do: @max_occurrences

  @doc """
  The occurrence start datetimes from `starts_at` (inclusive) through
  `until` (inclusive, compared as a calendar date in `timezone`),
  capped at #{@max_occurrences}.
  """
  @spec occurrence_starts(
          DateTime.t(),
          Kammer.Events.EventSeries.frequency(),
          Date.t(),
          String.t()
        ) :: [DateTime.t()]
  def occurrence_starts(starts_at, frequency, until, timezone) do
    local_start = DateTime.shift_zone!(starts_at, timezone)

    # Every occurrence is computed from the *original* start, not
    # chained off the previous one — chaining would drift a monthly
    # "the 31st" permanently down to the 28th/30th after the first
    # short month instead of snapping back when the day exists again.
    0
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(&occurrence_at(local_start, frequency, &1))
    |> Stream.take_while(&(Date.compare(DateTime.to_date(&1), until) != :gt))
    |> Enum.take(@max_occurrences)
    |> Enum.map(&DateTime.shift_zone!(&1, "Etc/UTC"))
  end

  defp occurrence_at(local_start, :weekly, index), do: shift_days(local_start, index * 7)
  defp occurrence_at(local_start, :biweekly, index), do: shift_days(local_start, index * 14)
  defp occurrence_at(local_start, :monthly, index), do: shift_months(local_start, index)

  defp shift_days(local_datetime, days) do
    date = local_datetime |> DateTime.to_date() |> Date.add(days)
    wall_clock!(date, DateTime.to_time(local_datetime), local_datetime.time_zone)
  end

  defp shift_months(local_datetime, months) do
    date = local_datetime |> DateTime.to_date() |> add_months(months)
    wall_clock!(date, DateTime.to_time(local_datetime), local_datetime.time_zone)
  end

  defp add_months(%Date{year: year, month: month, day: day}, months) do
    total = year * 12 + (month - 1) + months
    new_year = div(total, 12)
    new_month = rem(total, 12) + 1
    last_day_of_month = Date.days_in_month(%Date{year: new_year, month: new_month, day: 1})

    Date.new!(new_year, new_month, min(day, last_day_of_month))
  end

  # DST "spring forward": the wall-clock time doesn't exist that day
  # (e.g. 02:30 on the transition date) — resolve to the later valid
  # offset rather than fail the whole series. "Fall back" ambiguity
  # resolves the same way, for the same reason.
  defp wall_clock!(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} -> datetime
      {:ambiguous, _earlier, later} -> later
      {:gap, _before, after_gap} -> after_gap
    end
  end
end
