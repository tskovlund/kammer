defmodule KammerWeb.Api.PasskeyController do
  @moduledoc """
  Passkey enrollment over the API (issue #260 port 5b, ADR 0018): the
  authenticated half of WebAuthn, the twin of the usernameless sign-in
  ceremony in `AuthController`. `challenge` mints registration options
  for the signed-in caller; `create` verifies the attestation the
  browser produced and stores the credential; `index` lists the
  caller's passkeys; `delete` removes one.

  The ceremony runs statelessly, exactly as sign-in does: the
  `Wax.Challenge` travels to the client inside a signed, short-lived
  `challenge_token` rather than living in server-side session state,
  and comes back to `create` to verify the attestation against. Its
  salt is deliberately distinct from the sign-in challenge's, so a
  registration token can never be replayed as an authentication one (or
  vice versa).

  Everything is owner-scoped by construction — the context only ever
  reads or writes passkeys keyed to the authenticated user, so a
  foreign passkey id is simply not found — and `create` collapses every
  failure into one neutral 422 so it never reveals which step failed.
  """

  use KammerWeb, :controller

  alias Kammer.Accounts
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  # The signed registration challenge's whole lifetime — mirrors the
  # sign-in challenge's 2-minute window: a WebAuthn ceremony takes
  # seconds, and a short window bounds replay of a captured challenge.
  @registration_challenge_max_age_in_seconds 120

  # Distinct from the sign-in salt ("api passkey challenge") on purpose:
  # a registration token signed with this salt can never verify as an
  # authentication token, so the two ceremonies' tokens are not
  # interchangeable.
  @registration_challenge_salt "api passkey registration challenge"

  @doc """
  WebAuthn registration options for the signed-in caller. The browser
  feeds these to `navigator.credentials.create`; `exclude_credentials`
  lists the caller's already-registered credential ids so the
  authenticator won't enroll the same key twice. The challenge returns
  to `create` inside the signed, short-lived `challenge_token`.
  """
  @spec challenge(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def challenge(conn, _params) do
    user = conn.assigns.current_scope.user
    challenge = Accounts.new_passkey_registration_challenge(user, KammerWeb.Endpoint.url())

    exclude_credentials =
      user
      |> Accounts.list_passkeys()
      |> Enum.map(&Base.url_encode64(&1.credential_id, padding: false))

    json(conn, %{
      data: %{
        challenge: Base.url_encode64(challenge.bytes, padding: false),
        rp_id: challenge.rp_id,
        challenge_token:
          Phoenix.Token.sign(
            KammerWeb.Endpoint,
            @registration_challenge_salt,
            :erlang.term_to_binary(challenge)
          ),
        user_id: Base.url_encode64(user.id, padding: false),
        user_name: user.email,
        user_display_name: user.display_name,
        exclude_credentials: exclude_credentials
      }
    })
  end

  @doc """
  Verifies a registration attestation against the challenge minted by
  `challenge/2` and stores the passkey. Every failure mode — a stale or
  tampered challenge token, undecodable fields, a Wax verification
  failure, a duplicate credential — collapses into one neutral 422 that
  never says which step failed.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"challenge_token" => challenge_token} = params)
      when is_binary(challenge_token) do
    user = conn.assigns.current_scope.user

    with {:ok, challenge} <- verify_challenge_token(challenge_token),
         {:ok, attestation_object} <- decode_field(params, "attestation_object"),
         {:ok, client_data_json} <- decode_field(params, "client_data_json"),
         {:ok, passkey} <-
           Accounts.register_passkey(
             user,
             attestation_object,
             client_data_json,
             challenge,
             nickname(params)
           ) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.passkey(passkey)})
    else
      _error -> neutral_failure(conn)
    end
  end

  def create(conn, _params), do: neutral_failure(conn)

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    passkeys = Accounts.list_passkeys(conn.assigns.current_scope.user)
    json(conn, %{data: Enum.map(passkeys, &Serializer.passkey/1)})
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"passkey_id" => passkey_id}) do
    :ok = Accounts.delete_passkey(conn.assigns.current_scope.user, passkey_id)
    json(conn, %{status: "revoked"})
  end

  # Registration errors are deliberately indistinguishable: the client
  # gets one neutral message whether the token was tampered with, the
  # attestation failed Wax verification, or the credential was already
  # registered — no oracle for which step went wrong. `:unprocessable`
  # is the codebase's generic 422 (code "invalid_params").
  defp neutral_failure(conn),
    do: ApiError.send(conn, :unprocessable, "Could not register this passkey.")

  defp verify_challenge_token(challenge_token) do
    with {:ok, challenge_binary} <-
           Phoenix.Token.verify(KammerWeb.Endpoint, @registration_challenge_salt, challenge_token,
             max_age: @registration_challenge_max_age_in_seconds
           ) do
      # Signed by us in `challenge/2`, so the term is trusted;
      # non-executable + :safe is defense in depth.
      {:ok, Plug.Crypto.non_executable_binary_to_term(challenge_binary, [:safe])}
    end
  end

  defp decode_field(params, key) do
    case params[key] do
      value when is_binary(value) -> Base.url_decode64(value, padding: false)
      _missing -> :error
    end
  end

  # A blank nickname is no nickname — store nil, not "". Truncate rather
  # than let an over-long label fail the insert (which the neutral 422
  # would then report as if the whole registration were bad).
  @nickname_max_length 100
  defp nickname(params) do
    case params["nickname"] do
      value when is_binary(value) ->
        case value |> String.trim() |> String.slice(0, @nickname_max_length) do
          "" -> nil
          trimmed -> trimmed
        end

      _missing ->
        nil
    end
  end
end
