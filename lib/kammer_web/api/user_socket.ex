defmodule KammerWeb.Api.UserSocket do
  @moduledoc """
  Realtime entry point for API clients (ADR 0014: Phoenix Channels).

  Connects with a short-lived socket token (issue #175), minted over REST by
  `KammerWeb.Api.RealtimeController` from the device-token Bearer header and
  handed here as the `token` connect param. It is a ~60-second `Phoenix.Token`
  bound to the user and their device token's id, verified through
  `KammerWeb.Api.SocketToken` — so the long-lived device credential never
  rides in the websocket URL (which a fronting proxy could log), and revoking
  the device invalidates any outstanding socket token on the next connect.
  The REST revoke endpoint and instance ban also broadcast a disconnect on
  this socket's id, so a revoked device loses every live connection at once.
  Anonymous, expired, revoked, and banned connections are refused outright;
  per-topic authorization lives in each channel's `join/3`.
  """

  use Phoenix.Socket

  alias Kammer.Accounts
  alias Kammer.Accounts.User
  alias Kammer.Moderation
  alias KammerWeb.Api.SocketToken

  channel "feed:group:*", KammerWeb.Api.FeedChannel
  channel "notifications:user:*", KammerWeb.Api.NotificationChannel

  @impl Phoenix.Socket
  def connect(params, socket, _connect_info) do
    with {:ok, user_id, device_token_id} <- SocketToken.verify(params["token"]),
         # The socket token is short-lived, but a device revoked inside its
         # window must not still open a socket — re-check the device is active
         # and still owned by the claimed user (so a token pairing a user with
         # another user's device id is refused at the gate, not merely trusted
         # to have been paired correctly by the minting endpoint).
         true <- Accounts.device_token_active?(device_token_id, user_id),
         %User{} = user <- Accounts.get_user(user_id),
         # Full instance-ban lockout (#377): the realtime twin of the REST
         # `ApiAuth.ban_gate` — refuse the connection outright for a banned
         # account. The ban's `disconnect` broadcast severs live sockets, but
         # the client auto-reconnects, so gating here (not per push in each
         # channel) keeps the ban enforced once, at the transport, the way REST
         # enforces it once in the plug.
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
