defmodule Kammer.Calendar.ICSTest do
  @moduledoc """
  `ICS.filename/1` (issue #315): the download name for an ICS file,
  derived from an event or calendar title. A pure function, so tested
  directly here rather than through a controller — the endpoint tests
  in `calendar_test.exs` only pin the controllers' wiring to it.

  The load-bearing property is safety: the title is user-controlled and
  lands in a `Content-Disposition` header, so the output must always be
  a bare `[a-z0-9-]` slug (plus `.ics`) that can't break out of the
  header's quoting or inject a second one.
  """

  use ExUnit.Case, async: true

  alias Kammer.Calendar.ICS

  describe "filename/1" do
    test "transliterates Nordic and common accented letters to ASCII" do
      assert ICS.filename("Generalprøve") == "generalproeve.ics"
      assert ICS.filename("Sommerfest på taget") == "sommerfest-paa-taget.ics"
      assert ICS.filename("Café Ötzi") == "cafe-oetzi.ics"
    end

    test "collapses every non-slug run to a single dash and trims the ends" do
      assert ICS.filename("Åbning; med, komma!") == "aabning-med-komma.ics"
      assert ICS.filename("  spaced  out  ") == "spaced-out.ics"
    end

    test "falls back to kammer.ics when nothing slug-safe survives" do
      assert ICS.filename("🎉🎊") == "kammer.ics"
      assert ICS.filename("---") == "kammer.ics"
      assert ICS.filename("   ") == "kammer.ics"
      assert ICS.filename("") == "kammer.ics"
    end

    test "caps the slug so a runaway title can't produce an unbounded header" do
      # 60-char slug + ".ics".
      assert ICS.filename(String.duplicate("a", 100)) == String.duplicate("a", 60) <> ".ics"
    end

    test "a hostile title can never break out of the Content-Disposition header" do
      # CRLF, quotes, and a `; filename=` injection attempt all reduce to
      # the safe slug — the property the controllers rely on.
      hostile = ~s(evil"#{"\r\n"}X-Injected: 1"; filename=)
      result = ICS.filename(hostile)

      assert result =~ ~r/^[a-z0-9-]+\.ics$/
      refute result =~ "\r"
      refute result =~ "\n"
      refute result =~ ~s(")
    end
  end
end
