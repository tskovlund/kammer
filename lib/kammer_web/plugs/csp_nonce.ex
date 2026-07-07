defmodule KammerWeb.Plugs.CspNonce do
  @moduledoc """
  Pre-1.0 security hardening (SPEC §11): replaces the CSP's
  `script-src 'unsafe-inline'` with a fresh per-request nonce, assigned
  as `@csp_nonce` so the one inline script the app ships (the theme
  bootstrap in the root layout — colocated hooks compile into the
  external `app.js` bundle, so they need no nonce) can carry it.
  """

  import Plug.Conn

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", content_security_policy(nonce))
  end

  defp content_security_policy(nonce) do
    "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; " <>
      "script-src 'self' 'nonce-#{nonce}'; connect-src 'self' ws: wss:; " <>
      "object-src 'none'; frame-ancestors 'self'; base-uri 'self'"
  end
end
