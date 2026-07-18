defmodule KammerWeb.Api.AccountController do
  @moduledoc """
  Account lifecycle over the API (issue #258, SPEC §12 data rights):
  email change, self-serve export, and account deletion — the API
  twins of the LiveView settings flows that disappear with the #187
  cut.

  **Email change** mirrors the web flow's semantics: the request
  endpoint emails a single-use confirmation link to the *new* address
  (rate-limited per acting user,
  `Kammer.RateLimit.hit_email_change/1`), and nothing changes until
  the confirm endpoint consumes the token. Initiation sits behind the
  step-up gate (issue #294, ADR 0029): the account email is the root
  credential in a passwordless model — every future magic link goes to
  it — so changing it is exactly the credential change the gate
  exists for. (An earlier iteration shipped ungated on the reasoning
  that "device tokens have no re-auth equivalent"; the step-up
  machinery made that rationale false, and the owner's option-B call
  on #294 reversed it.) The link lands in the PWA (ADR 0024) — the
  landing page calls the
  confirm endpoint with the device token it already holds, since the
  token is bound to the requesting account, not a credential on its
  own. Confirming invalidates every device token by construction
  (they're bound to the address they were issued under —
  `UserToken.verify_device_token_query/1`), so the confirm response
  rotates the calling device's credential: it carries a fresh
  `device_token` the client swaps in, while every other device signs
  out — the conservative reading of an account-identity change.

  **Deletion and export sit behind the step-up gate too** (issue
  #323, widening ADR 0029's original scope): deletion is one
  irreversible request a token thief could fire as pure destruction,
  and the export bundles every stored byte of the account's PII into
  a single response — both worth more to an attacker than to a
  scripted accident.

  **Deletion confirmation semantics**: the request must carry the
  account's own email typed back (`confirm_email`; mismatch is a
  422). This is accidental-click protection, *not* a security
  control — an attacker holding the device token can read the address
  from `GET /me` and type it back, so the step-up gate above is the
  security layer and this check stacks beneath it. What the typed
  email stops is the
  one honest failure mode: a reflexive or scripted DELETE. The
  response is sent after the row is gone — the conn was authenticated
  at the start of the request, so answering 200 as the account
  vanishes is fine; every other credential dies with the cascade, and
  the user-socket broadcast severs any websockets already open.
  """

  use KammerWeb, :controller

  import KammerWeb.ApiStepUp, only: [require_stepped_up: 2]

  require Logger

  alias Kammer.Accounts
  alias Kammer.Accounts.UserNotifier
  alias Kammer.RateLimit
  alias Kammer.Gdpr
  alias KammerWeb.Api.PublicLinks
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiAuth
  alias KammerWeb.ApiError

  # Changing the root credential requires a fresh step-up (issue #294,
  # ADR 0029). Only initiation: the confirm endpoint consumes a
  # single-use token already bound to this account, and gating it too
  # would strand the legitimate flow when the window expires mid-email.
  # Deletion and export joined the gated set on #323 (ADR 0029 update):
  # ADR 0029's original exclusion reasoned about credential takeover,
  # but a token thief needs no persistence to destroy the account
  # outright or to pull every stored byte of PII in one request. The
  # typed-back-email check in `delete` still runs after the gate —
  # accidental-click protection layered on top, not replaced.
  plug :require_stepped_up when action in [:request_email_change, :export, :delete]

  @spec request_email_change(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request_email_change(conn, %{"email" => email} = _params) when is_binary(email) do
    user = conn.assigns.current_scope.user

    # Spend the budget BEFORE the uniqueness check: a taken address
    # answers 422 and a free one 200, so an unthrottled request would
    # be a registered/unregistered enumeration oracle — the step-up
    # gate narrows who can probe, but a stepped-up caller must still
    # be throttled. `deliver_...` no longer re-checks — the limit is
    # consumed here, once, for every request.
    case RateLimit.hit_email_change(user.id) do
      {:allow, _count} ->
        case Accounts.change_user_email(user, %{"email" => email}) do
          %{valid?: true} = changeset -> deliver_email_change(conn, user, changeset)
          changeset -> ApiError.from_result(conn, {:error, changeset})
        end

      {:deny, _retry} ->
        ApiError.from_result(conn, {:error, :rate_limited})
    end
  end

  def request_email_change(conn, _params),
    do: ApiError.send(conn, :bad_request, "An email address is required.")

  @spec confirm_email_change(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm_email_change(conn, %{"token" => token}) when is_binary(token) do
    # Read the calling credential's row before the change — afterwards
    # the old token no longer verifies (it's bound to the old address).
    current_device =
      case ApiAuth.bearer_token(conn) do
        nil -> nil
        bearer -> Accounts.get_device_token(bearer)
      end

    old_email = conn.assigns.current_scope.user.email

    case Accounts.update_user_email(conn.assigns.current_scope.user, token) do
      {:ok, user} ->
        device_token = rotate_device_token(user, current_device)

        # The old address gets told (issue #258): even with the
        # step-up gate on initiation (#294), this notice is the one
        # signal a hijacked account's real owner still receives once a
        # change lands. Best-effort —
        # an SMTP hiccup must not fail the already-completed change —
        # but a failure is logged, since it's the security signal.
        case UserNotifier.deliver_email_changed_notice(user, old_email, user.email) do
          {:ok, _email} ->
            :ok

          error ->
            Logger.warning("email-changed notice to #{old_email} failed: #{inspect(error)}")
        end

        # Sever live sockets: every other device's token just died with
        # the address change, so leaving their websockets streaming
        # would outlive the credential (same reasoning as revocation).
        # The confirming client reconnects with the fresh token.
        KammerWeb.Endpoint.broadcast("api_user_socket:#{user.id}", "disconnect", %{})
        json(conn, %{data: Serializer.profile(user), device_token: device_token})

      # Expired, already used, tampered, or issued for a different
      # account — one neutral answer, like the guest confirms.
      {:error, _reason} ->
        ApiError.send(conn, :not_found, "That confirmation link is invalid or has expired.")
    end
  end

  def confirm_email_change(conn, _params),
    do: ApiError.send(conn, :bad_request, "A token is required.")

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, params) do
    user = conn.assigns.current_scope.user

    if confirms_email?(params, user.email) do
      :ok = Gdpr.delete_account(user)

      # Sever live sockets — the cascade already deleted every token
      # row, but an open websocket would keep streaming until it
      # happened to reconnect (same reasoning as device revocation).
      KammerWeb.Endpoint.broadcast("api_user_socket:#{user.id}", "disconnect", %{})
      json(conn, %{status: "deleted"})
    else
      ApiError.send(
        conn,
        :unprocessable,
        "confirm_email must match your account's email address."
      )
    end
  end

  @spec export(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def export(conn, _params) do
    user = conn.assigns.current_scope.user

    # Throttled: Gdpr.export reads every uploaded file into memory to
    # build the zip, so an unthrottled trigger is a memory amplifier.
    case RateLimit.hit_data_export(user.id) do
      {:allow, _count} -> stream_export(conn, user)
      {:deny, _retry} -> ApiError.from_result(conn, {:error, :rate_limited})
    end
  end

  defp stream_export(conn, user) do
    case Gdpr.export(user) do
      {:ok, zip_path} ->
        # `after` so the workdir (data.json, file copies, the zip) is
        # cleaned even if send_download raises or the client aborts —
        # Gdpr.export leaves cleanup to the caller, and orphaned
        # workdirs would otherwise fill the temp dir over time.
        try do
          conn
          # A personal data export must never sit in a shared cache (#315).
          |> put_resp_header("cache-control", "private, no-store")
          |> send_download({:file, zip_path},
            filename: "kammer-export-#{Date.to_iso8601(Date.utc_today())}.zip"
          )
        after
          File.rm_rf(Path.dirname(zip_path))
        end

      {:error, _reason} ->
        ApiError.send(conn, :bad_request, "The export failed — please try again.")
    end
  end

  # Replaces the calling device's now-dead credential with a fresh one
  # under the same name, then purges the account's OTHER api-device
  # rows: the address change killed them all (they verify on
  # `sent_to == user.email`), so leaving them would show signed-out
  # phones as live on the devices page. Session tokens are untouched.
  defp rotate_device_token(user, current_device) do
    fresh = Accounts.create_device_token(user, current_device && current_device.user_agent)
    Accounts.purge_stale_api_devices(user, Accounts.get_device_token(fresh).id)
    fresh
  end

  defp deliver_email_change(conn, user, changeset) do
    case Accounts.deliver_user_update_email_instructions(
           Ecto.Changeset.apply_action!(changeset, :insert),
           user.email,
           &PublicLinks.confirm_url(conn, :email_change, &1),
           check_rate_limit: false
         ) do
      {:error, :rate_limited} = error -> ApiError.from_result(conn, error)
      _sent -> json(conn, %{status: "confirmation_sent"})
    end
  end

  # The typed-back email confirms intent, not identity — so it matches
  # the address case-insensitively, like the citext column stores it.
  defp confirms_email?(%{"confirm_email" => typed}, email) when is_binary(typed),
    do: String.downcase(String.trim(typed)) == String.downcase(email)

  defp confirms_email?(_params, _email), do: false
end
