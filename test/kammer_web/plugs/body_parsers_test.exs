defmodule KammerWeb.Plugs.BodyParsersTest do
  @moduledoc """
  The endpoint's request-body length ceiling must track `UPLOAD_MAX_MB`
  at runtime instead of the hardcoded literal it used to be (issue
  #234, ADR 0027) — while still being a real, enforced bound (the
  CVE-2026-56814 Plug bump this repo already carries was about exactly
  this multipart-length accounting).
  """

  # async: false — mutates the global :upload_max_megabytes app env.
  use ExUnit.Case, async: false

  import Plug.Test

  alias KammerWeb.Plugs.BodyParsers

  defp with_upload_limit(megabytes) do
    previous = Application.fetch_env(:kammer, :upload_max_megabytes)
    Application.put_env(:kammer, :upload_max_megabytes, megabytes)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:kammer, :upload_max_megabytes, value)
        :error -> Application.delete_env(:kammer, :upload_max_megabytes)
      end
    end)
  end

  defp urlencoded_conn(body) do
    :post
    |> conn("/", body)
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
  end

  test "a body under the ceiling is parsed normally" do
    with_upload_limit(1)

    conn = BodyParsers.call(urlencoded_conn("foo=bar"), [])

    assert conn.params["foo"] == "bar"
  end

  test "a body over the ceiling is rejected (413), tracking the configured upload limit" do
    with_upload_limit(1)

    # Just over Kammer.Files.upload_limit_bytes() (1 MB) plus the
    # fixed multipart/urlencoded headroom.
    oversized = "x=" <> :binary.copy("a", Kammer.Files.upload_limit_bytes() + 23_500_000)

    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      BodyParsers.call(urlencoded_conn(oversized), [])
    end
  end

  test "the ceiling rises when UPLOAD_MAX_MB rises" do
    with_upload_limit(200)

    # Bigger than the historical fixed 128_000_000-byte ceiling, but
    # still under the new one derived from the raised limit.
    body = "x=" <> :binary.copy("a", 128_100_000)

    conn = BodyParsers.call(urlencoded_conn(body), [])

    assert conn.params["x"]
  end
end
