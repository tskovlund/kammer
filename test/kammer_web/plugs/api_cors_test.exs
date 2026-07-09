defmodule KammerWeb.Plugs.ApiCorsTest do
  @moduledoc """
  CORS policy for the JSON API (issue #150): wildcard by default,
  optionally restricted via `config :kammer, :api_allowed_origins`;
  never applied outside `/api/`.
  """

  # async: false — several tests mutate the global :api_allowed_origins
  # app env.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias KammerWeb.Plugs.ApiCors

  defp restrict_origins(origins) do
    previous = Application.fetch_env(:kammer, :api_allowed_origins)
    Application.put_env(:kammer, :api_allowed_origins, origins)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:kammer, :api_allowed_origins, value)
        :error -> Application.delete_env(:kammer, :api_allowed_origins)
      end
    end)
  end

  test "wildcard by default on API paths" do
    conn = :get |> conn("/api/v1/home") |> ApiCors.call([])

    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    refute conn.halted
  end

  test "untouched outside /api, including preflights" do
    conn = :get |> conn("/") |> ApiCors.call([])
    assert get_resp_header(conn, "access-control-allow-origin") == []

    preflight =
      :options
      |> conn("/users/log-in")
      |> put_req_header("origin", "https://evil.example")
      |> put_req_header("access-control-request-method", "POST")
      |> ApiCors.call([])

    assert get_resp_header(preflight, "access-control-allow-origin") == []
    refute preflight.halted
  end

  test "answers API preflights directly with 204 and the CORS grant" do
    conn =
      :options
      |> conn("/api/v1/home")
      |> put_req_header("origin", "https://app.example.org")
      |> put_req_header("access-control-request-method", "GET")
      |> ApiCors.call([])

    assert conn.halted
    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    [methods] = get_resp_header(conn, "access-control-allow-methods")
    assert methods =~ "GET"
    assert methods =~ "DELETE"

    assert get_resp_header(conn, "access-control-allow-headers") == [
             "authorization, content-type"
           ]

    assert get_resp_header(conn, "access-control-max-age") == ["86400"]
  end

  test "echoes the headers the preflight asks for" do
    conn =
      :options
      |> conn("/api/v1/home")
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", "authorization, x-custom")
      |> ApiCors.call([])

    assert get_resp_header(conn, "access-control-allow-headers") == ["authorization, x-custom"]
  end

  test "an OPTIONS request without access-control-request-method is not a preflight" do
    conn = :options |> conn("/api/v1/home") |> ApiCors.call([])

    refute conn.halted
  end

  test "restricted mode echoes an allowed origin and varies on Origin" do
    restrict_origins(["https://app.example.org"])

    conn =
      :get
      |> conn("/api/v1/home")
      |> put_req_header("origin", "https://app.example.org")
      |> ApiCors.call([])

    assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.example.org"]
    assert get_resp_header(conn, "vary") == ["origin"]
  end

  test "an empty configured list means unset, not deny-all" do
    restrict_origins([])

    conn = :get |> conn("/api/v1/home") |> ApiCors.call([])

    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "matching survives trailing slashes and case differences in the configured list" do
    restrict_origins(["https://App.Example.org/"])

    conn =
      :get
      |> conn("/api/v1/home")
      |> put_req_header("origin", "https://app.example.org")
      |> ApiCors.call([])

    assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.example.org"]
  end

  test "restricted mode grants nothing to other origins or origin-less requests" do
    restrict_origins(["https://app.example.org"])

    denied =
      :get
      |> conn("/api/v1/home")
      |> put_req_header("origin", "https://evil.example")
      |> ApiCors.call([])

    assert get_resp_header(denied, "access-control-allow-origin") == []
    assert get_resp_header(denied, "vary") == ["origin"]

    origin_less = :get |> conn("/api/v1/home") |> ApiCors.call([])
    assert get_resp_header(origin_less, "access-control-allow-origin") == []
  end
end

defmodule KammerWeb.Plugs.ApiCorsIntegrationTest do
  @moduledoc """
  The plug must act from the endpoint: an OPTIONS preflight matches no
  router route, so anything later than the endpoint would 404 before
  the browser gets its grant.
  """

  use KammerWeb.ConnCase, async: true

  test "a real API response carries the wildcard grant", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/instance")

    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "a preflight to an authenticated API route succeeds without auth or a matching route",
       %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://app.example.org")
      |> put_req_header("access-control-request-method", "GET")
      |> options(~p"/api/v1/home")

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "browser-facing routes stay same-origin", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert get_resp_header(conn, "access-control-allow-origin") == []
  end
end
