defmodule KammerWeb.Api.RealtimeController do
  @moduledoc """
  Mints the short-lived token a client uses to open the realtime websocket
  (issue #175). Authenticated with the long-lived device token in the
  `Authorization` header — the header, never the URL — this returns a
  ~60-second `Phoenix.Token` the client hands to `UserSocket.connect/3` as
  the socket's connect param, so the device token itself never travels in a
  query string a fronting proxy could log.
  """

  use KammerWeb, :controller

  alias Kammer.Accounts
  alias KammerWeb.Api.SocketToken
  alias KammerWeb.ApiAuth
  alias KammerWeb.ApiError

  @spec token(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def token(conn, _params) do
    user = conn.assigns.current_scope.user

    # The request already authenticated via this device token (the pipeline's
    # `require_api_user`), so re-resolving it to its row id is a hit; binding
    # the socket token to that id lets `UserSocket` reject it the moment the
    # device is revoked.
    case Accounts.get_device_token(ApiAuth.bearer_token(conn)) do
      %Accounts.UserToken{id: device_token_id} ->
        json(conn, %{
          data: %{
            token: SocketToken.sign(user.id, device_token_id),
            expires_in: SocketToken.max_age_seconds()
          }
        })

      nil ->
        # Unreachable behind `require_api_user` (a device-token scope means the
        # token resolved); answered honestly rather than crashing on nil.id.
        ApiError.send(conn, :unauthorized, "A valid device token is required.")
    end
  end
end
