defmodule KammerWeb.Plugs.ApiCors do
  @moduledoc """
  CORS for the JSON API (issue #150). Policy, decided by the owner:
  wildcard (`Access-Control-Allow-Origin: *`) by default, optionally
  restricted to a comma-separated origin list via the
  `API_ALLOWED_ORIGINS` env var (`config :kammer, :api_allowed_origins`).

  Wildcard is safe here because API auth is a Bearer device token
  (ADR 0014), never a cookie — a malicious page cannot make the browser
  attach a token it doesn't already hold, so there is no
  ambient-credential/CSRF exposure. The multi-instance client model
  (ADR 0001) needs any-origin by default: any self-hosted Svelte PWA at
  any domain talks to any Kammer instance.

  Lives in the endpoint, not the `:api` router pipeline: OPTIONS
  preflights match no route, so a pipeline plug would 404 before ever
  setting a header. Scoped to `/api/` paths only — the
  cookie-authenticated LiveView app keeps the browser's same-origin
  default.
  """

  @behaviour Plug

  import Plug.Conn

  @allowed_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  @default_allowed_headers "authorization, content-type"
  @max_age_seconds "86400"

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{path_info: ["api" | _]} = conn, _opts) do
    if preflight?(conn) do
      conn
      |> put_origin_header()
      |> put_resp_header("access-control-allow-methods", @allowed_methods)
      |> put_resp_header("access-control-allow-headers", requested_headers(conn))
      |> put_resp_header("access-control-max-age", @max_age_seconds)
      |> send_resp(204, "")
      |> halt()
    else
      put_origin_header(conn)
    end
  end

  def call(conn, _opts), do: conn

  defp preflight?(%Plug.Conn{method: "OPTIONS"} = conn),
    do: get_req_header(conn, "access-control-request-method") != []

  defp preflight?(_conn), do: false

  defp put_origin_header(conn) do
    case Application.get_env(:kammer, :api_allowed_origins) do
      # An empty list means "nothing configured", not "deny everyone" —
      # runtime.exs never sets one, but a stray empty env value must not
      # silently flip the API from open to fully blocked.
      empty when empty in [nil, []] ->
        put_resp_header(conn, "access-control-allow-origin", "*")

      allowed_origins when is_list(allowed_origins) ->
        # The response now depends on the Origin request header, so
        # caches must key on it. Prepend rather than put: a later Vary
        # writer must not clobber this, nor this an earlier one.
        conn = prepend_resp_headers(conn, [{"vary", "origin"}])

        with [origin] <- get_req_header(conn, "origin"),
             true <- normalize(origin) in Enum.map(allowed_origins, &normalize/1) do
          put_resp_header(conn, "access-control-allow-origin", origin)
        else
          # No Origin header or an origin outside the list: no CORS
          # headers, the browser enforces the block.
          _ -> conn
        end
    end
  end

  # Browsers serialize Origin as lowercase scheme://host[:port] with no
  # path; a hand-configured allow-list entry habitually arrives with a
  # trailing slash or mixed case, which would otherwise never match.
  defp normalize(origin) do
    origin |> String.trim() |> String.trim_trailing("/") |> String.downcase()
  end

  defp requested_headers(conn) do
    case get_req_header(conn, "access-control-request-headers") do
      [] -> @default_allowed_headers
      headers -> Enum.join(headers, ", ")
    end
  end
end
