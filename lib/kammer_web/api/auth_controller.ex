defmodule KammerWeb.Api.AuthController do
  @moduledoc """
  API sign-in (ADR 0014): a passwordless JSON flow. `register` creates
  an account (same changeset and per-IP rate limit as direct
  registration); `request_link` emails a magic link that deep-links
  into the instance-served PWA plus a short cross-device sign-in code
  (neutral response — no account enumeration); `exchange` trades either
  single-use credential for a long-lived device token; the passkey pair
  (issue #177, ADR 0018) runs the WebAuthn assertion ceremony
  statelessly — the challenge travels to the client signed, in a
  short-lived token rather than server-side process state; `revoke`
  signs the device out.
  """

  use KammerWeb, :controller

  alias Kammer.Accounts
  alias Kammer.Moderation
  alias KammerWeb.ApiAuth
  alias KammerWeb.ApiError
  alias KammerWeb.Api.PublicLinks

  # The signed challenge's whole lifetime — mirrors the 2-minute
  # passkey exchange token on the web flow: a WebAuthn ceremony takes
  # seconds, and a short window bounds replay of a captured
  # challenge/assertion pair (which TLS already makes moot).
  @passkey_challenge_max_age_in_seconds 120
  @passkey_challenge_salt "api passkey challenge"

  @spec register(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def register(conn, params) do
    attrs = Map.take(params, ["email", "display_name"])

    case Accounts.register_user(attrs, ip: conn.remote_ip) do
      {:ok, user} ->
        Accounts.deliver_login_instructions(
          user,
          fn token -> PublicLinks.sign_in_url(conn, token) end,
          ip: conn.remote_ip,
          code: true
        )

        conn
        |> put_status(201)
        |> json(%{status: "confirmation_sent", user: user_payload(user)})

      error ->
        ApiError.from_result(conn, error)
    end
  end

  @spec request_link(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request_link(conn, %{"email" => email}) when is_binary(email) do
    # Full instance-ban lockout (#377): don't deliver a sign-in link to a
    # banned address — it could not be exchanged for a session anyway, but
    # the link should never be sent. The response stays identical to the
    # unknown-address case, so neither existence nor ban status leaks.
    with %Accounts.User{} = user <- Accounts.get_user_by_email(email),
         false <- Moderation.instance_banned?(user.email) do
      Accounts.deliver_login_instructions(
        user,
        fn token -> PublicLinks.sign_in_url(conn, token) end,
        ip: conn.remote_ip,
        code: true
      )
    end

    # Deliberately identical for unknown addresses (SPEC §11).
    json(conn, %{status: "sent"})
  end

  def request_link(conn, _params),
    do: ApiError.send(conn, :bad_request, "An email address is required.")

  @spec exchange(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def exchange(conn, %{"magic_token" => magic_token} = params) when is_binary(magic_token) do
    case Accounts.exchange_magic_link_for_device_token(magic_token, params["device_name"]) do
      {:ok, device_token, user} ->
        json(conn, %{device_token: device_token, user: user_payload(user)})

      {:error, :not_found} ->
        ApiError.send(conn, :unauthorized, "That sign-in link is invalid or has expired.")
    end
  end

  def exchange(conn, %{"email" => email, "code" => code} = params)
      when is_binary(email) and is_binary(code) do
    case Accounts.exchange_login_code_for_device_token(email, code, params["device_name"],
           ip: conn.remote_ip
         ) do
      {:ok, device_token, user} ->
        json(conn, %{device_token: device_token, user: user_payload(user)})

      {:error, :rate_limited} = error ->
        ApiError.from_result(conn, error)

      # Wrong code, expired code, and unknown email are one answer —
      # this endpoint must not confirm which emails have accounts.
      {:error, :not_found} ->
        ApiError.send(conn, :unauthorized, "That sign-in code is invalid or has expired.")
    end
  end

  def exchange(conn, _params),
    do: ApiError.send(conn, :bad_request, "A magic_token, or an email and code, is required.")

  @doc """
  WebAuthn assertion options for a usernameless passkey sign-in (ADR
  0018): like the web flow, no email is asked for and no
  `allow_credentials` is set — the browser offers its resident
  credentials and the credential id identifies the user — so there is
  no account-enumeration surface by construction. The challenge
  returns to `passkey_verify` inside a signed, short-lived
  `challenge_token`, replacing the LiveView process state the web
  ceremony keeps it in.
  """
  @spec passkey_challenge(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def passkey_challenge(conn, _params) do
    challenge = Accounts.new_passkey_authentication_challenge(KammerWeb.Endpoint.url())

    json(conn, %{
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      rp_id: challenge.rp_id,
      challenge_token:
        Phoenix.Token.sign(
          KammerWeb.Endpoint,
          @passkey_challenge_salt,
          :erlang.term_to_binary(challenge)
        )
    })
  end

  @doc """
  Verifies a passkey assertion against the challenge minted by
  `passkey_challenge` and answers with the same shape as `exchange`.
  Every failure mode — bad signature, unknown credential, stale or
  tampered challenge token, undecodable fields — collapses into one
  neutral 401.
  """
  @spec passkey_verify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def passkey_verify(conn, %{"challenge_token" => challenge_token} = params)
      when is_binary(challenge_token) do
    with {:ok, challenge} <- verify_challenge_token(challenge_token),
         {:ok, credential_id} <- decode_assertion_field(params, "credential_id"),
         {:ok, authenticator_data} <- decode_assertion_field(params, "authenticator_data"),
         {:ok, signature} <- decode_assertion_field(params, "signature"),
         {:ok, client_data_json} <- decode_assertion_field(params, "client_data_json"),
         {:ok, user} <-
           Accounts.login_user_by_passkey(
             credential_id,
             authenticator_data,
             signature,
             client_data_json,
             challenge
           ) do
      device_token = Accounts.create_device_token(user, params["device_name"])
      json(conn, %{device_token: device_token, user: user_payload(user)})
    else
      _error ->
        ApiError.send(conn, :unauthorized, "That passkey sign-in didn't work.")
    end
  end

  def passkey_verify(conn, _params),
    do:
      ApiError.send(conn, :bad_request, "A challenge_token and WebAuthn assertion are required.")

  @spec revoke(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def revoke(conn, _params) do
    case ApiAuth.bearer_token(conn) do
      nil -> :ok
      token -> Accounts.revoke_device_token(token)
    end

    # Sever live sockets too — deleting the token row alone would
    # leave an already-open websocket streaming for as long as it
    # stays connected. The socket id is per user, so sibling devices
    # just reconnect with their still-valid tokens.
    KammerWeb.Endpoint.broadcast(
      "api_user_socket:#{conn.assigns.current_scope.user.id}",
      "disconnect",
      %{}
    )

    json(conn, %{status: "revoked"})
  end

  defp user_payload(user),
    do: %{id: user.id, email: user.email, display_name: user.display_name}

  defp verify_challenge_token(challenge_token) do
    with {:ok, challenge_binary} <-
           Phoenix.Token.verify(KammerWeb.Endpoint, @passkey_challenge_salt, challenge_token,
             max_age: @passkey_challenge_max_age_in_seconds
           ) do
      # Signed by us above, so the term is trusted; non-executable +
      # :safe is defense in depth.
      {:ok, Plug.Crypto.non_executable_binary_to_term(challenge_binary, [:safe])}
    end
  end

  defp decode_assertion_field(params, key) do
    case params[key] do
      value when is_binary(value) -> Base.url_decode64(value, padding: false)
      _missing -> :error
    end
  end
end
