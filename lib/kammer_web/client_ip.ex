defmodule KammerWeb.ClientIp do
  @moduledoc """
  Recovers the real client IP from `X-Forwarded-For` — but only when
  the TCP peer is an operator-configured trusted proxy (issue #162).

  Rate limits (SPEC §11) key on the client IP. Behind the documented
  reverse-proxy deployment every request reaches the app from the
  proxy's address, so without this policy the per-IP limits are
  instance-wide: one abuser exhausts everyone's signup and magic-link
  budget. But `X-Forwarded-For` is client-controlled on any connection
  that does not come from the proxy (the compose file publishes the
  app port), so trusting it unconditionally would let an attacker
  rotate spoofed addresses and defeat the limiter entirely.

  Policy — `TRUSTED_PROXIES` (comma-separated IPs/CIDRs, stored as
  `config :kammer, :trusted_proxies`) names the proxies allowed to
  speak for clients:

    * Unset/empty (the default): the header is ignored entirely —
      safe for direct deployments, where the peer already is the
      client.
    * Peer inside a trusted CIDR: the client is the rightmost
      `X-Forwarded-For` address that is not itself a trusted proxy.
      Entries further left are attacker-suppliable and never reach
      the limiter; an unparseable entry stops the walk (with a
      warning) and keeps the peer rather than trusting anything
      beyond it.
    * Peer outside every trusted CIDR: the header is ignored — a
      client that reaches the port directly cannot spoof, no matter
      what it sends.

  One policy, two entry points: the module is a `Plug` (rewrites
  `conn.remote_ip` in the endpoint pipeline) and a LiveView helper
  (`client_ip_from_socket/1` — socket upgrades bypass the plug
  pipeline, so mounts apply the same policy to `peer_data` +
  `x_headers` connect info).

  Deliberately hand-rolled instead of the `remote_ip` hex package
  (SPEC §22 prefers the minimal internal version over a mismatched
  dependency, with the reason stated): that library never consults
  the TCP peer — a forwarding header is honored whenever one is
  present, so any client that can reach the app port directly can
  spoof — and it hard-codes loopback/private ranges as proxies,
  handing header trust to any Docker-network or LAN peer and
  collapsing genuine LAN clients onto the proxy's key. Closing #162
  means peer-gating and inverting those defaults, which is this
  entire module.
  """

  @behaviour Plug

  import Bitwise

  require Logger

  @forwarded_for_header "x-forwarded-for"

  @typedoc "A parsed CIDR block: protocol, network integer, mask integer."
  @type block() :: {:v4 | :v6, non_neg_integer(), non_neg_integer()}

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    %{conn | remote_ip: client_ip(conn.remote_ip, conn.req_headers)}
  end

  @doc """
  The client IP for a LiveView socket, from its `peer_data` and
  `x_headers` connect info — the same trusted-proxy policy as the
  plug. Nil when the socket has no peer data (static render, tests).
  """
  @spec client_ip_from_socket(Phoenix.LiveView.Socket.t()) :: :inet.ip_address() | nil
  def client_ip_from_socket(socket) do
    client_ip_from_connect_info(
      Phoenix.LiveView.get_connect_info(socket, :peer_data),
      Phoenix.LiveView.get_connect_info(socket, :x_headers)
    )
  end

  @doc """
  `client_ip_from_socket/1`'s core, separated so the policy is
  testable without a socket: resolves `peer_data` + `x_headers`
  connect info, either of which may be nil.
  """
  @spec client_ip_from_connect_info(map() | nil, [{binary(), binary()}] | nil) ::
          :inet.ip_address() | nil
  def client_ip_from_connect_info(%{address: address}, x_headers),
    do: client_ip(address, x_headers)

  def client_ip_from_connect_info(_missing_peer_data, _x_headers), do: nil

  @doc """
  Resolves the client IP for `peer` given request headers, honoring
  `X-Forwarded-For` only when `peer` is a configured trusted proxy.
  """
  @spec client_ip(:inet.ip_address(), [{binary(), binary()}] | nil) :: :inet.ip_address()
  def client_ip(peer, nil), do: peer

  def client_ip(peer, headers) when is_list(headers) do
    case trusted_blocks() do
      [] ->
        peer

      blocks ->
        if trusted?(peer, blocks) do
          forwarded_client(headers, blocks) || peer
        else
          peer
        end
    end
  end

  @doc """
  Parses the configured trusted-proxy CIDRs, raising on any invalid
  entry. Called from `Kammer.Application.start/2` so a typo'd
  `TRUSTED_PROXIES` fails the boot loudly (the #98 pattern) instead
  of 500ing on the first request.
  """
  @spec validate_config!() :: :ok
  def validate_config! do
    _blocks = trusted_blocks()
    :ok
  end

  # The raw config is a list of CIDR strings (runtime.exs splits the
  # env var). Parsed blocks are cached in :persistent_term keyed by
  # the raw list — the config never changes within a running node, so
  # this parses once per boot (plus once per distinct value tests set).
  defp trusted_blocks do
    case Application.get_env(:kammer, :trusted_proxies, []) do
      [] ->
        []

      raw_cidrs ->
        case :persistent_term.get({__MODULE__, raw_cidrs}, nil) do
          nil ->
            blocks = Enum.map(raw_cidrs, &parse_cidr!/1)
            :persistent_term.put({__MODULE__, raw_cidrs}, blocks)
            blocks

          blocks ->
            blocks
        end
    end
  end

  @spec parse_cidr!(String.t()) :: block()
  defp parse_cidr!(cidr) when is_binary(cidr) do
    {address, prefix} =
      case String.split(cidr, "/", parts: 2) do
        [address] -> {address, nil}
        [address, prefix] -> {address, prefix}
      end

    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(address)),
         {:ok, block} <- block(ip, prefix) do
      block
    else
      _error ->
        raise ArgumentError,
              "invalid TRUSTED_PROXIES entry #{inspect(cidr)} " <>
                "(expected an IP address or CIDR block, e.g. 127.0.0.1 or 10.0.0.0/8)"
    end
  end

  defp block({_, _, _, _} = ip, prefix) do
    with {:ok, prefix_length} <- prefix_length(prefix, 32) do
      <<mask::32>> = <<bnot(0xFFFFFFFF >>> prefix_length)::32>>
      {:ok, {:v4, ip_to_integer(ip) &&& mask, mask}}
    end
  end

  defp block({_, _, _, _, _, _, _, _} = ip, prefix) do
    with {:ok, prefix_length} <- prefix_length(prefix, 128) do
      ones = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
      <<mask::128>> = <<bnot(ones >>> prefix_length)::128>>
      {:ok, {:v6, ip_to_integer(ip) &&& mask, mask}}
    end
  end

  defp prefix_length(nil, width), do: {:ok, width}

  defp prefix_length(prefix, width) when is_binary(prefix) do
    case Integer.parse(prefix) do
      {length, ""} when length in 0..32 and width == 32 -> {:ok, length}
      {length, ""} when length in 0..128 and width == 128 -> {:ok, length}
      _invalid -> :error
    end
  end

  # Matching normalizes IPv4-mapped IPv6 internally (see unmap/1), so
  # callers pass addresses exactly as received.
  defp trusted?(ip, blocks) do
    encoded = ip |> unmap() |> encode()
    Enum.any?(blocks, &block_contains?(&1, encoded))
  end

  defp block_contains?({proto, net, mask}, {proto, ip}), do: (ip &&& mask) == net
  defp block_contains?(_block, _encoded_ip), do: false

  defp encode({_, _, _, _} = ip), do: {:v4, ip_to_integer(ip)}
  defp encode({_, _, _, _, _, _, _, _} = ip), do: {:v6, ip_to_integer(ip)}

  defp ip_to_integer({a, b, c, d}) do
    <<n::32>> = <<a::8, b::8, c::8, d::8>>
    n
  end

  defp ip_to_integer({a, b, c, d, e, f, g, h}) do
    <<n::128>> = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    n
  end

  # A dual-stack listener (PHX_LISTEN_IPV6) reports IPv4 peers as
  # IPv4-mapped IPv6 addresses; treat them as their IPv4 form so
  # TRUSTED_PROXIES=127.0.0.1 works regardless of listener family and
  # the limiter keys one client one way.
  defp unmap({0, 0, 0, 0, 0, 0xFFFF, g, h}),
    do: {g >>> 8, g &&& 0xFF, h >>> 8, h &&& 0xFF}

  defp unmap(ip), do: ip

  # Rightmost X-Forwarded-For entry that is not itself a trusted
  # proxy. Nil when there is no such entry (no header, all hops
  # trusted, or a malformed hop before any client was found).
  defp forwarded_client(headers, blocks) do
    headers
    |> Enum.filter(fn {name, _value} -> name == @forwarded_for_header end)
    |> Enum.flat_map(fn {_name, value} -> String.split(value, ",") end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reverse()
    |> first_untrusted_hop(blocks)
  end

  defp first_untrusted_hop([], _blocks), do: nil

  defp first_untrusted_hop([entry | earlier_hops], blocks) do
    case parse_forwarded_entry(entry) do
      {:ok, ip} ->
        if trusted?(ip, blocks), do: first_untrusted_hop(earlier_hops, blocks), else: unmap(ip)

      :error ->
        # A malformed hop means the chain cannot be trusted past this
        # point — everything further left is attacker-suppliable, so
        # fall back to the peer. Warn loudly: when the malformed entry
        # is what the trusted proxy itself appends (a format this
        # parser doesn't cover), every client silently collapses onto
        # the proxy's rate-limit key — the exact failure this module
        # exists to prevent, so make it findable in the logs.
        Logger.warning(
          "client_ip: unparseable X-Forwarded-For entry #{inspect(entry)} " <>
            "from a trusted proxy — falling back to the peer address"
        )

        nil
    end
  end

  # Strict IP parse, plus the port-carrying forms some proxies emit
  # ("203.0.113.7:4711", "[2001:db8::1]:4711", "[2001:db8::1]") —
  # without these, such a proxy would silently collapse all clients
  # onto its own rate-limit key via the malformed-hop fallback.
  defp parse_forwarded_entry("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [address, suffix] when suffix == "" or binary_part(suffix, 0, 1) == ":" ->
        parse_forwarded_entry(address)

      _invalid ->
        :error
    end
  end

  defp parse_forwarded_entry(entry) do
    case :inet.parse_strict_address(String.to_charlist(entry)) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _reason} ->
        # "a.b.c.d:port" — IPv4 only: a bare IPv6 address contains
        # colons itself, so stripping a "port" from it would be
        # ambiguous (bracketed IPv6 is handled above).
        with [address, port] <- String.split(entry, ":", parts: 2),
             {_port_number, ""} <- Integer.parse(port),
             {:ok, {_, _, _, _} = ip} <-
               :inet.parse_strict_address(String.to_charlist(address)) do
          {:ok, ip}
        else
          _error -> :error
        end
    end
  end
end
