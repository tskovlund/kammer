defmodule KammerWeb.Api.StepUpController do
  @moduledoc """
  Step-up re-authentication (issue #294, ADR 0029): before a
  credential change, a signed-in device re-asserts a root of trust —
  either a passkey assertion or an emailed confirmation link — and the
  proof lands as `stepped_up_at` on the *calling* device-token row.
  Nothing is minted here: no session, no device token, no elevation
  that could outlive or travel beyond the credential that asked.

  **Passkey method** (`passkey_challenge`/`passkey_verify`, authed):
  the sign-in assertion ceremony run statelessly, with two deliberate
  differences. The challenge token is signed with its own salt, so a
  step-up challenge can never be replayed as a sign-in or registration
  one; and because `Accounts.login_user_by_passkey/5` is usernameless
  (it returns whoever owns the credential), verify additionally
  asserts the credential's owner IS the caller — without that check
  any valid passkey for any account would step this device up. The
  challenge response also scopes `allow_credentials` to the caller's
  own credentials, so the browser never offers a passkey that could
  only fail. Failures collapse into one neutral 422 (the enrollment
  ceremony's convention — no oracle for which step went wrong; and not
  401, which API clients read as "signed out").

  **Email method** (`request_link` authed → `confirm` public): the
  request emails the account's own address a single-use link bound to
  the calling device row. The link may well be opened in a different
  browser than the app (mobile mail apps, cross-device mailboxes), so
  `confirm` is deliberately public — the 32-byte single-use token is
  the whole credential, exactly like every other emailed confirm here
  — and only ever flips `stepped_up_at` on the one row the token was
  minted for. The requesting client then simply retries its original
  action.
  """

  use KammerWeb, :controller

  alias Kammer.Accounts
  alias KammerWeb.Api.PublicLinks
  alias KammerWeb.ApiAuth
  alias KammerWeb.ApiError

  # Mirrors the sign-in and registration ceremonies' 2-minute window: a
  # WebAuthn ceremony takes seconds, and a short window bounds replay
  # of a captured challenge.
  @step_up_challenge_max_age_in_seconds 120

  # Distinct from both the sign-in salt ("api passkey challenge") and
  # the registration salt on purpose: a step-up challenge token must
  # never verify as either sibling ceremony's (or vice versa).
  @step_up_challenge_salt "api passkey step-up challenge"

  @doc """
  WebAuthn assertion options for a step-up (authed). Unlike sign-in,
  `allow_credentials` lists the caller's registered credential ids —
  we know who is asking, and the browser should only offer passkeys
  that can succeed. An account with no passkeys gets an empty list;
  the client offers the email method instead.
  """
  @spec passkey_challenge(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def passkey_challenge(conn, _params) do
    user = conn.assigns.current_scope.user
    challenge = Accounts.new_passkey_authentication_challenge(KammerWeb.Endpoint.url())

    allow_credentials =
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
            @step_up_challenge_salt,
            :erlang.term_to_binary(challenge)
          ),
        allow_credentials: allow_credentials
      }
    })
  end

  @doc """
  Verifies a step-up passkey assertion and marks the calling device
  token stepped up. Every failure mode — stale/tampered challenge
  token, undecodable fields, a bad assertion, a credential owned by a
  DIFFERENT account — collapses into one neutral 422.
  """
  @spec passkey_verify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def passkey_verify(conn, %{"challenge_token" => challenge_token} = params)
      when is_binary(challenge_token) do
    caller = conn.assigns.current_scope.user

    with {:ok, challenge} <- verify_challenge_token(challenge_token),
         {:ok, credential_id} <- decode_assertion_field(params, "credential_id"),
         {:ok, authenticator_data} <- decode_assertion_field(params, "authenticator_data"),
         {:ok, signature} <- decode_assertion_field(params, "signature"),
         {:ok, client_data_json} <- decode_assertion_field(params, "client_data_json"),
         {:ok, verified_user} <-
           Accounts.login_user_by_passkey(
             credential_id,
             authenticator_data,
             signature,
             client_data_json,
             challenge
           ),
         # login_user_by_passkey is usernameless — it answers with the
         # credential's owner, whoever that is. Only the caller's own
         # passkey may step the caller up.
         true <- verified_user.id == caller.id,
         %Accounts.UserToken{} = device <- current_device(conn),
         # A concurrent sign-out/revoke deleting the row mid-request
         # reads as the same neutral failure — never a 500.
         {:ok, _device} <- Accounts.step_up_device(device) do
      json(conn, %{status: "stepped_up"})
    else
      _error -> neutral_failure(conn)
    end
  end

  def passkey_verify(conn, _params), do: neutral_failure(conn)

  @doc """
  Emails the account's own address a step-up confirmation link bound
  to the calling device (authed; shares the magic-link email budget).
  Always answers `{status: "sent"}` on an allowed request — whether
  the email later bounces is not this endpoint's to reveal.
  """
  @spec request_link(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request_link(conn, _params) do
    user = conn.assigns.current_scope.user

    case current_device(conn) do
      # Only reachable in the race where the token was revoked between
      # the auth plug and here — then there is no row left to step up.
      nil ->
        ApiError.send(conn, :unauthorized, "A valid device token is required.")

      device ->
        case Accounts.deliver_step_up_instructions(
               user,
               device,
               fn token -> PublicLinks.confirm_url(conn, :step_up, token) end,
               ip: conn.remote_ip
             ) do
          {:error, :rate_limited} = error ->
            ApiError.from_result(conn, error)

          # A mailer hiccup reads as sent, like the email-change request
          # (AccountController) — the token row exists either way, and
          # "resend" is the natural human retry.
          _sent ->
            json(conn, %{status: "sent"})
        end
    end
  end

  @doc """
  Consumes the emailed step-up token (public — the link may land in a
  different browser than the requesting app, so no Bearer can be
  required; the single-use token is the whole credential). Expired,
  spent, tampered, and unknown tokens are one neutral 404, like every
  other emailed confirm.
  """
  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"token" => token}) when is_binary(token) do
    case Accounts.confirm_step_up(token) do
      {:ok, _device} ->
        json(conn, %{status: "stepped_up"})

      {:error, :not_found} ->
        ApiError.send(conn, :not_found, "That confirmation link is invalid or has expired.")
    end
  end

  def confirm(conn, _params),
    do: ApiError.send(conn, :bad_request, "A token is required.")

  # The calling credential's own row — the only thing a step-up may
  # ever elevate.
  defp current_device(conn) do
    case ApiAuth.bearer_token(conn) do
      nil -> nil
      token -> Accounts.get_device_token(token)
    end
  end

  # One neutral answer for every verify failure (the passkey no-oracle
  # convention, matching PasskeyController's registration 422): the
  # response never says whether the token, the assertion, or the
  # credential's ownership was at fault.
  defp neutral_failure(conn),
    do: ApiError.send(conn, :unprocessable, "Could not confirm it's you with that passkey.")

  defp verify_challenge_token(challenge_token) do
    with {:ok, challenge_binary} <-
           Phoenix.Token.verify(KammerWeb.Endpoint, @step_up_challenge_salt, challenge_token,
             max_age: @step_up_challenge_max_age_in_seconds
           ) do
      # Signed by us in `passkey_challenge/2`, so the term is trusted;
      # non-executable + :safe is defense in depth.
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
