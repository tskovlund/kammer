defmodule KammerWeb.ApiStepUp do
  @moduledoc """
  The step-up gate for credential-changing API endpoints (issue #294,
  ADR 0029): a request passes only when the calling api-device token
  row was stepped up — re-asserted a root of trust via
  `KammerWeb.Api.StepUpController` — within the configured window
  (`Kammer.Config.step_up_validity_minutes/0`).

  Gated surface (the actions whose effect outlives, or severs, the
  calling credential): passkey enrollment and removal, revoking a
  *different* device, and initiating an email change. Self-revoke
  (sign-out) stays ungated — it only destroys the caller's own
  credential, which mere possession already allows. Account deletion
  and the GDPR export joined the set on #323 (ADR 0029 update):
  irreversible destruction and one-shot bulk PII exfiltration are
  exactly what a transient token thief wants, even without
  persistence.
  """

  import Plug.Conn, only: [halt: 1]

  alias Kammer.Accounts
  alias KammerWeb.ApiAuth
  alias KammerWeb.ApiError

  @doc """
  Controller plug: halts with the 401 `step_up_required` envelope
  unless the calling device token is freshly stepped up.
  """
  @spec require_stepped_up(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_stepped_up(conn, _opts) do
    if stepped_up?(conn) do
      conn
    else
      conn |> refuse() |> halt()
    end
  end

  @doc """
  Whether the request's Bearer device token is freshly stepped up —
  for endpoints that gate conditionally (foreign-device revoke) rather
  than via the plug.
  """
  @spec stepped_up?(Plug.Conn.t()) :: boolean()
  def stepped_up?(conn) do
    case ApiAuth.bearer_token(conn) do
      nil -> false
      token -> token |> Accounts.get_device_token() |> Accounts.device_stepped_up?()
    end
  end

  @doc "The standard 401 `step_up_required` envelope."
  @spec refuse(Plug.Conn.t()) :: Plug.Conn.t()
  def refuse(conn) do
    ApiError.send(
      conn,
      :step_up_required,
      "Recent confirmation required — step up via /auth/step-up and retry."
    )
  end
end
