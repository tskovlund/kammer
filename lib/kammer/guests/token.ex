defmodule Kammer.Guests.Token do
  @moduledoc """
  Signed, expiring tokens for guest links (SPEC §11: every guest-facing
  link is signed and expiring). Stateless by design — a guest holds no
  session, so the link *is* the credential: confirm links prove control
  of the email address, management links authorize changing or erasing
  exactly one guest's records.

  Signing uses the endpoint's `secret_key_base` via `Plug.Crypto`
  directly, so contexts stay free of web-layer modules.
  """

  @confirm_salt "guest confirm"
  @manage_salt "guest manage"

  # Long enough to find the email, short enough that a leaked confirm
  # link goes stale quickly.
  @confirm_max_age_seconds 60 * 60 * 48
  # Management links live as long as changing an answer stays useful:
  # issued fresh with every confirmation email.
  @manage_max_age_seconds 60 * 60 * 24 * 60

  @doc "Signs a confirm-intent payload (email round-trip proof)."
  @spec sign_confirm(term()) :: String.t()
  def sign_confirm(payload), do: Plug.Crypto.sign(secret(), @confirm_salt, payload)

  @doc "Verifies a confirm token."
  @spec verify_confirm(String.t()) :: {:ok, term()} | {:error, atom()}
  def verify_confirm(token),
    do: Plug.Crypto.verify(secret(), @confirm_salt, token, max_age: @confirm_max_age_seconds)

  @doc "Signs a management-link payload."
  @spec sign_manage(term()) :: String.t()
  def sign_manage(payload), do: Plug.Crypto.sign(secret(), @manage_salt, payload)

  @doc "Verifies a management token."
  @spec verify_manage(String.t()) :: {:ok, term()} | {:error, atom()}
  def verify_manage(token),
    do: Plug.Crypto.verify(secret(), @manage_salt, token, max_age: @manage_max_age_seconds)

  defp secret do
    Application.get_env(:kammer, KammerWeb.Endpoint)[:secret_key_base]
  end
end
