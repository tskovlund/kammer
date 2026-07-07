defmodule KammerWeb.Plugs.CspNonceTest do
  @moduledoc """
  Pre-1.0 CSP hardening (SPEC §11): script-src drops 'unsafe-inline'
  for a fresh per-request nonce.
  """

  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias KammerWeb.Plugs.CspNonce

  test "assigns a nonce and puts it in a nonce-based script-src, no unsafe-inline" do
    conn = :get |> conn("/") |> CspNonce.call([])

    assert is_binary(conn.assigns.csp_nonce)
    assert byte_size(conn.assigns.csp_nonce) > 0

    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "script-src 'self' 'nonce-#{conn.assigns.csp_nonce}'"
    refute csp =~ "script-src 'self' 'unsafe-inline'"
  end

  test "generates a different nonce per call" do
    conn1 = :get |> conn("/") |> CspNonce.call([])
    conn2 = :get |> conn("/") |> CspNonce.call([])

    refute conn1.assigns.csp_nonce == conn2.assigns.csp_nonce
  end
end

defmodule KammerWeb.Plugs.CspNonceIntegrationTest do
  @moduledoc """
  A real page's CSP header nonce must match the one on its inline
  theme-bootstrap script, or the browser blocks it.
  """

  use KammerWeb.ConnCase, async: true

  test "the root page's script nonce matches the CSP header, and differs across requests" do
    conn = get(build_conn(), ~p"/")
    [csp] = get_resp_header(conn, "content-security-policy")

    assert [_, nonce] = Regex.run(~r/nonce-([^']+)/, csp)
    assert html_response(conn, 200) =~ ~s(<script nonce="#{nonce}">)

    other_conn = get(build_conn(), ~p"/")
    [other_csp] = get_resp_header(other_conn, "content-security-policy")
    refute other_csp == csp
  end
end
