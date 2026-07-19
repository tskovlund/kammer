defmodule KammerWeb.Api.UserSocket do
  @moduledoc """
  Realtime entry point for API clients (ADR 0014: Phoenix Channels).
  Connects with the same device token the REST API takes as a Bearer
  header — passed as the `token` connect param, resolved through the
  same `Kammer.Accounts` lookup; the API revoke endpoint also
  broadcasts a disconnect on this socket's id, so a revoked device
  loses both transports at once. Anonymous connections are refused
  outright; per-topic authorization lives in each channel's `join/3`.

  Known trade-off: connect params travel in the websocket URL, so a
  fronting proxy that logs full request paths captures the token
  (Phoenix's own logger filters it). A short-lived socket-only token
  minted over REST would close that; tracked as a follow-up issue.
  """

  use Phoenix.Socket

  alias Kammer.Accounts
  alias Kammer.Accounts.User
  alias Kammer.Moderation

  channel "feed:group:*", KammerWeb.Api.FeedChannel
  channel "notifications:user:*", KammerWeb.Api.NotificationChannel

  @impl Phoenix.Socket
  def connect(params, socket, _connect_info) do
    with token when is_binary(token) <- params["token"],
         %User{} = user <- Accounts.get_user_by_device_token(token),
         # Full instance-ban lockout (#377): the realtime twin of the REST
         # `ApiAuth.ban_gate` — refuse the connection outright for a banned
         # account. The ban's `disconnect` broadcast severs live sockets, but
         # the client auto-reconnects, so a token that outlives the ban would
         # walk straight back in without this. Gating here (not per push in
         # each channel) keeps the ban enforced once, at the transport, the
         # way REST enforces it once in the plug.
         false <- Moderation.instance_banned?(user.email) do
      {:ok, assign(socket, :current_user, user)}
    else
      _invalid_or_banned -> :error
    end
  end

  # One id per user so `KammerWeb.Endpoint.broadcast("api_user_socket:...",
  # "disconnect", %{})` can sever every live connection when a device
  # token is revoked.
  @impl Phoenix.Socket
  def id(socket), do: "api_user_socket:#{socket.assigns.current_user.id}"
end
