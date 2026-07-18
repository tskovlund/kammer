defmodule Kammer.Calendar.ICS do
  @moduledoc """
  ICS (RFC 5545) generation for events (SPEC §6): single-event files for
  "add to calendar" / email attachments, and calendar feeds per group and
  per user. Generated directly — the format for simple VEVENTs is small
  and stable, and direct generation keeps timezone handling explicit
  (all times are exported as UTC; all-day events as VALUE=DATE in the
  event's own timezone).
  """

  alias Kammer.Events.Event

  @doc """
  A complete VCALENDAR document for the given events.
  """
  @spec calendar([Event.t()], String.t()) :: String.t()
  def calendar(events, calendar_name) do
    lines =
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Kammer//Kammer//EN",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        "X-WR-CALNAME:#{escape(calendar_name)}"
      ] ++
        Enum.flat_map(events, &event_lines/1) ++
        ["END:VCALENDAR"]

    lines
    |> Enum.map(&fold_line/1)
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  @doc """
  A single-event VCALENDAR document.
  """
  @spec single(Event.t()) :: String.t()
  def single(%Event{} = event), do: calendar([event], event.title)

  @doc """
  A readable, safe `.ics` download name from an event or calendar title
  (#315): the prior static `kammer.ics` made every saved file identical,
  so a member downloading several couldn't tell them apart. Reduced to a
  bare `[a-z0-9-]` slug — Nordic letters transliterated, every other run
  collapsed to a single dash — so no title character can break out of the
  `Content-Disposition` header, with `kammer.ics` as the fallback when a
  title has no usable characters (e.g. all emoji). Shared by both the
  browser and API calendar controllers so the two agree.
  """
  @spec filename(String.t()) :: String.t()
  def filename(name) do
    slug =
      name
      |> String.downcase()
      |> transliterate()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.slice(0, 60)
      |> String.trim("-")

    if slug == "", do: "kammer.ics", else: "#{slug}.ics"
  end

  defp transliterate(text) do
    text
    |> String.replace(["æ", "ä"], "ae")
    |> String.replace(["ø", "ö"], "oe")
    |> String.replace("å", "aa")
    |> String.replace(["é", "è", "ê"], "e")
    |> String.replace("ü", "ue")
  end

  defp event_lines(%Event{} = event) do
    [
      "BEGIN:VEVENT",
      "UID:#{event.id}@kammer",
      "DTSTAMP:#{format_datetime(event.updated_at || event.starts_at)}",
      dtstart(event),
      dtend(event),
      "SUMMARY:#{escape(event.title)}",
      description(event),
      location(event),
      status(event),
      "END:VEVENT"
    ]
    |> Enum.reject(&is_nil/1)
  end

  # A cancelled occurrence downloaded on its own must not look live:
  # STATUS:CANCELLED marks it off in the calendar rather than planting a
  # normal-looking event. (Whether a *re*-download updates a copy the
  # subscriber already imported is best-effort under METHOD:PUBLISH with
  # no SEQUENCE — DTSTAMP-gated clients accept it, SEQUENCE-gated ones
  # may not; proper iTIP revision handling is tracked separately.) The
  # feeds exclude cancelled occurrences upstream, so this only bites the
  # single-event surface today, but the generator marks any cancelled
  # event it's handed, whatever the surface.
  defp status(%Event{cancelled_at: nil}), do: nil
  defp status(%Event{}), do: "STATUS:CANCELLED"

  # All-day events use VALUE=DATE in the event's own timezone wall-date.
  defp dtstart(%Event{all_day: true} = event) do
    "DTSTART;VALUE=DATE:#{format_date(event.starts_at, event.timezone)}"
  end

  defp dtstart(%Event{} = event), do: "DTSTART:#{format_datetime(event.starts_at)}"

  defp dtend(%Event{ends_at: nil, all_day: true} = event) do
    # A one-day all-day event ends the following day per RFC 5545.
    next_day = DateTime.add(event.starts_at, 1, :day)
    "DTEND;VALUE=DATE:#{format_date(next_day, event.timezone)}"
  end

  defp dtend(%Event{ends_at: nil}), do: nil

  defp dtend(%Event{all_day: true} = event) do
    inclusive_end = DateTime.add(event.ends_at, 1, :day)
    "DTEND;VALUE=DATE:#{format_date(inclusive_end, event.timezone)}"
  end

  defp dtend(%Event{} = event), do: "DTEND:#{format_datetime(event.ends_at)}"

  defp description(%Event{description_markdown: nil}), do: nil

  defp description(%Event{description_markdown: markdown}) do
    "DESCRIPTION:#{escape(markdown)}"
  end

  defp location(%Event{location_name: nil, location_url: nil}), do: nil

  defp location(%Event{} = event) do
    location_text =
      [event.location_name, event.location_url]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" — ")

    "LOCATION:#{escape(location_text)}"
  end

  defp format_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp format_date(%DateTime{} = datetime, timezone) do
    datetime
    |> DateTime.shift_zone!(valid_timezone(timezone))
    |> DateTime.to_date()
    |> Calendar.strftime("%Y%m%d")
  end

  defp valid_timezone(timezone) do
    case DateTime.now(timezone) do
      {:ok, _now} -> timezone
      {:error, _reason} -> "Etc/UTC"
    end
  end

  defp escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    # Every line-break variant collapses to one escaped `\n`. Beyond
    # CRLF/CR/LF (RFC-strict parsers only break a content line on CRLF,
    # but real calendar clients break on a bare CR too — #313), the
    # Unicode-aware unfolders some clients use (e.g. .NET's line
    # splitters) also break on NEL and the line/paragraph separators, so
    # those inject property lines just the same. Order: CRLF before the
    # lone-CR and lone-LF passes, or the split halves double-escape.
    |> String.replace("\r\n", "\\n")
    |> String.replace("\r", "\\n")
    |> String.replace("\n", "\\n")
    |> String.replace("\u{0085}", "\\n")
    |> String.replace("\u{2028}", "\\n")
    |> String.replace("\u{2029}", "\\n")
    # Remaining control characters are dropped (TAB stays — it's
    # permitted). C0 + DEL are RFC 5545 CONTROLs, forbidden in TEXT
    # outright (byte-oriented regex). The C1 range (U+0080–U+009F,
    # codepoint-oriented, needs the `u` flag) is *permitted* by the
    # grammar as NON-US-ASCII, but stripped as defense-in-depth: a
    # lenient or Unicode-aware client may still honor one as a control,
    # and these have no legitimate use in these fields. NEL (U+0085) is
    # already handled above.
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    |> String.replace(~r/[\x{0080}-\x{009F}]/u, "")
  end

  # RFC 5545: lines longer than 75 octets should be folded.
  defp fold_line(line) when byte_size(line) <= 75, do: line

  defp fold_line(line) do
    {head, tail} = split_at_bytes(line, 75)
    head <> "\r\n " <> fold_line(tail)
  end

  defp split_at_bytes(string, limit) do
    do_split_at_bytes(string, limit, "")
  end

  defp do_split_at_bytes(rest, remaining, accumulated) do
    case String.next_grapheme(rest) do
      nil ->
        {accumulated, ""}

      {grapheme, tail} ->
        grapheme_size = byte_size(grapheme)

        if grapheme_size > remaining do
          {accumulated, rest}
        else
          do_split_at_bytes(tail, remaining - grapheme_size, accumulated <> grapheme)
        end
    end
  end
end
