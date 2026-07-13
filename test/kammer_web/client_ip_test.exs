defmodule KammerWeb.ClientIpTest do
  @moduledoc """
  Trusted-proxy client IP recovery (issue #162): X-Forwarded-For is
  honored only when the TCP peer is an operator-listed proxy — never
  from a direct client — and the rate limiter really keys on the
  recovered address.
  """

  # async: false — :trusted_proxies is global application env, and the
  # rate-limiter test spends real budget in Hammer's shared ETS table.
  use KammerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias KammerWeb.ClientIp

  # TEST-NET peers/clients so the budgets spent here can never collide
  # with other tests' limiter keys (test conns default to 127.0.0.1).
  @proxy {203, 0, 113, 250}
  @direct_client {203, 0, 113, 1}

  defp trust_proxies(cidrs) do
    Application.put_env(:kammer, :trusted_proxies, cidrs)
    on_exit(fn -> Application.delete_env(:kammer, :trusted_proxies) end)
  end

  defp resolve(peer, forwarded_for) do
    conn =
      build_conn()
      |> Map.put(:remote_ip, peer)
      |> put_req_header("x-forwarded-for", forwarded_for)

    ClientIp.call(conn, []).remote_ip
  end

  describe "call/2" do
    test "with no trusted proxies a spoofed X-Forwarded-For is ignored" do
      # Naive header trust would resolve this to the spoofed 6.6.6.6
      # and fail here — that is the spoof this plug exists to reject.
      assert resolve(@direct_client, "6.6.6.6") == @direct_client
    end

    test "an untrusted peer cannot spoof even when proxies are configured" do
      trust_proxies(["10.0.0.0/8"])

      assert resolve(@direct_client, "6.6.6.6") == @direct_client
    end

    test "the client IP is recovered from a trusted proxy" do
      trust_proxies(["203.0.113.250"])

      assert resolve(@proxy, "198.51.100.7") == {198, 51, 100, 7}
    end

    test "chained trusted hops are walked past; attacker-supplied prefixes are never reached" do
      trust_proxies(["203.0.113.250", "10.0.0.0/8"])

      # "6.6.6.6" is what the client itself sent; the proxies appended
      # the rest. The rightmost untrusted address wins.
      assert resolve(@proxy, "6.6.6.6, 198.51.100.7, 10.0.0.3") == {198, 51, 100, 7}
    end

    test "a private-range client behind the proxy keeps its own address" do
      # LAN self-hosting: private ranges are ordinary clients here,
      # not implicit proxies (the remote_ip package's contrary default
      # is one reason this is hand-rolled).
      trust_proxies(["203.0.113.250"])

      assert resolve(@proxy, "192.168.1.50") == {192, 168, 1, 50}
    end

    test "a malformed hop left of a valid client never disturbs the selection" do
      # The walk must stop at the rightmost untrusted VALID hop — an
      # implementation that eagerly parsed every entry (and fell back
      # to the peer on any malformed one) would collapse this client
      # onto the proxy key.
      trust_proxies(["203.0.113.250"])

      assert resolve(@proxy, "not-an-ip, 198.51.100.7") == {198, 51, 100, 7}
    end

    test "when every hop is a trusted proxy the peer keys the request" do
      # No untrusted hop exists to speak for — collapsing to the peer
      # is the safe floor, never a spoof vector.
      trust_proxies(["203.0.113.250", "10.0.0.0/8"])

      assert resolve(@proxy, "10.0.0.3, 10.0.0.4") == @proxy
    end

    test "repeated X-Forwarded-For header lines fold in order" do
      # Proxies append; Plug folds repeated lines left-to-right, so the
      # nearest hop is the rightmost entry of the last line — that one
      # must win the walk.
      trust_proxies(["203.0.113.250", "10.0.0.0/8"])

      conn =
        build_conn()
        |> Map.put(:remote_ip, @proxy)
        |> put_req_header("x-forwarded-for", "6.6.6.6")
        |> Plug.Conn.prepend_req_headers([{"x-forwarded-for", "203.0.113.9"}])

      assert ClientIp.call(conn, []).remote_ip == {6, 6, 6, 6}
    end

    test "port-carrying entries from port-appending proxies still resolve" do
      # Some proxies emit "ip:port"; failing to parse these would
      # silently collapse every client onto the proxy's key.
      trust_proxies(["203.0.113.250"])

      assert resolve(@proxy, "198.51.100.7:52344") == {198, 51, 100, 7}
      assert resolve(@proxy, "[2001:db8::7]:52344") == {8193, 3512, 0, 0, 0, 0, 0, 7}
      assert resolve(@proxy, "[2001:db8::7]") == {8193, 3512, 0, 0, 0, 0, 0, 7}
    end

    test "a malformed hop falls back to the peer, with a warning" do
      trust_proxies(["203.0.113.250"])

      log =
        capture_log(fn ->
          assert resolve(@proxy, "198.51.100.7, not-an-ip") == @proxy
        end)

      assert log =~ "unparseable X-Forwarded-For"
    end

    test "an IPv4-mapped IPv6 peer matches its IPv4 CIDR (dual-stack listener)" do
      trust_proxies(["203.0.113.250"])
      mapped_proxy = {0, 0, 0, 0, 0, 0xFFFF, 203 * 256 + 0, 113 * 256 + 250}

      assert resolve(mapped_proxy, "198.51.100.7") == {198, 51, 100, 7}
    end
  end

  describe "validate_config!/0" do
    test "raises on an invalid CIDR so boot fails instead of the first request" do
      trust_proxies(["999.0.0.0/8"])

      assert_raise ArgumentError, ~r/TRUSTED_PROXIES.*999\.0\.0\.0/s, fn ->
        ClientIp.validate_config!()
      end
    end
  end

  describe "rate limiting through the endpoint" do
    test "signup limits key on the forwarded client, per client, behind a trusted proxy" do
      trust_proxies(["203.0.113.250"])

      register = fn forwarded_for, email ->
        build_conn()
        |> Map.put(:remote_ip, @proxy)
        |> put_req_header("x-forwarded-for", forwarded_for)
        |> put_req_header("accept", "application/json")
        |> post(~p"/api/v1/auth/register", %{"email" => email, "display_name" => "XFF"})
      end

      # Client A burns its own 10-per-hour signup budget...
      for attempt <- 1..10 do
        assert register.("198.51.100.61", "xff-a-#{attempt}@example.org").status == 201
      end

      assert register.("198.51.100.61", "xff-a-11@example.org")
             |> json_response(429)

      # ...while client B, arriving through the same proxy, is unaffected —
      # the limiter keys on the recovered client IP, not the proxy's.
      assert register.("198.51.100.62", "xff-b-1@example.org").status == 201
    end
  end
end
