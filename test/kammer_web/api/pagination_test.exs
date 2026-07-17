defmodule KammerWeb.Api.PaginationTest do
  @moduledoc """
  The shared cursor/limit parsing (RFC 0001). Phoenix turns
  `after[]=x` / `limit[k]=v` query strings into lists and maps, so
  both functions must treat non-scalar input as absent — a crash here
  is a caller-triggerable 500 on every paginated endpoint (#340
  review). These arms are unreachable through the endpoint suites'
  well-formed requests, hence the unit pins.
  """

  use ExUnit.Case, async: true

  alias KammerWeb.Api.Pagination

  test "hostile after shapes read as no cursor, never a crash" do
    assert Pagination.decode(["zzz"]) == nil
    assert Pagination.decode(%{"a" => "b"}) == nil
    assert Pagination.decode("not-a-cursor") == nil
  end

  test "limit falls back to the default on absent, garbage, or non-scalar input" do
    assert Pagination.limit(%{}) == 25
    assert Pagination.limit(%{"limit" => "abc"}) == 25
    assert Pagination.limit(%{"limit" => %{"a" => "b"}}) == 25
    assert Pagination.limit(%{"limit" => ["9"]}, 50) == 50
  end

  test "an explicit limit wins over a custom default; the ceiling clamps both" do
    assert Pagination.limit(%{"limit" => "7"}, 50) == 7
    assert Pagination.limit(%{"limit" => "999"}, 50) == 50
    # No caller can widen the ceiling through the default parameter.
    assert Pagination.limit(%{}, 150) == 100
  end
end
