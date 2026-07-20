defmodule KammerWeb.Api.SocketToken do
  @moduledoc """
  A short-lived token that authenticates a websocket connect (issue #175),
  so the long-lived API device token never rides in the socket URL where a
  fronting proxy or CDN could log it.

  Minted over REST (`POST /api/v1/realtime/token`, device-token Bearer auth)
  and verified in `KammerWeb.Api.UserSocket.connect/3`. The payload carries
  both the user id and the **device token's** id, so `UserSocket` can confirm
  the device is still active on connect — revoking the device invalidates any
  outstanding socket token within its short lifetime.

  The salt and max-age live here, referenced by both the minting controller
  and the socket, so the two ends of the contract can never drift.
  """

  @salt "api socket token"
  @max_age_seconds 60

  @doc "The lifetime clients should assume, in seconds."
  @spec max_age_seconds() :: pos_integer()
  def max_age_seconds, do: @max_age_seconds

  @doc "Signs a socket token binding the connect to a user and their device token."
  @spec sign(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def sign(user_id, device_token_id) do
    Phoenix.Token.sign(KammerWeb.Endpoint, @salt, {user_id, device_token_id})
  end

  @doc """
  Verifies a socket token minted by `sign/2`, returning the bound user and
  device-token ids. Refuses a token older than `max_age_seconds/0`, tampered,
  or of the wrong shape.
  """
  @spec verify(term()) :: {:ok, Ecto.UUID.t(), Ecto.UUID.t()} | {:error, atom()}
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(KammerWeb.Endpoint, @salt, token, max_age: @max_age_seconds) do
      {:ok, {user_id, device_token_id}} when is_binary(user_id) and is_binary(device_token_id) ->
        {:ok, user_id, device_token_id}

      {:ok, _unexpected_shape} ->
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify(_not_a_token), do: {:error, :invalid}
end
