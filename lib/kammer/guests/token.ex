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
  @unsubscribe_salt "guest unsubscribe"

  # Long enough to find the email, short enough that a leaked confirm
  # link goes stale quickly.
  @confirm_max_age_seconds 60 * 60 * 48
  # Management links live as long as changing an answer stays useful:
  # issued fresh with every confirmation email.
  @manage_max_age_seconds 60 * 60 * 24 * 60
  # Unsubscribe tokens carry no identity, only a `subscription_id`
  # (issue #233) — possession authorizes unsubscribing exactly that one
  # subscription and nothing else, so it's low-impact by construction
  # even long after issue. Pick generously (180 days, well past the
  # 60-day manage token) so an old newsletter email's unsubscribe link
  # — and the auto-fetched `List-Unsubscribe` header it doubles as —
  # keeps working for as long as a subscription realistically lives.
  @unsubscribe_max_age_seconds 60 * 60 * 24 * 180

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

  @doc """
  Signs a scoped unsubscribe payload — a single-purpose credential
  (issue #233) distinct from the full-power management token: a
  different salt, so it never verifies against `verify_manage/1`, and a
  payload carrying only the one subscription it authorizes (never an
  identity), so it can't be replayed against any other record.
  """
  @spec sign_unsubscribe(term()) :: String.t()
  def sign_unsubscribe(payload), do: Plug.Crypto.sign(secret(), @unsubscribe_salt, payload)

  @doc "Verifies a scoped unsubscribe token."
  @spec verify_unsubscribe(String.t()) :: {:ok, term()} | {:error, atom()}
  def verify_unsubscribe(token),
    do:
      Plug.Crypto.verify(secret(), @unsubscribe_salt, token,
        max_age: @unsubscribe_max_age_seconds
      )

  defp secret do
    Application.get_env(:kammer, KammerWeb.Endpoint)[:secret_key_base]
  end
end
