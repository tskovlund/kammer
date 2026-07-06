defmodule Kammer.RateLimit do
  @moduledoc """
  Central rate limiter (SPEC §11): magic-link issuance (per email and per
  IP), signup, posting/commenting, guest endpoints, uploads, and @everyone
  all take their limits from here so policy lives in one place.

  Backed by Hammer's ETS backend — per-node counters, which is sufficient
  for the single-node deployment model of v1.
  """

  use Hammer, backend: :ets

  @fifteen_minutes_in_milliseconds 15 * 60 * 1000

  @doc """
  Rate limit for requesting a magic sign-in link, keyed by email address.

  Allows 3 requests per address per 15 minutes.
  """
  @spec hit_magic_link_email(String.t()) :: {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_magic_link_email(email) when is_binary(email) do
    hit("magic_link:email:#{String.downcase(email)}", @fifteen_minutes_in_milliseconds, 3)
  end

  @doc """
  Rate limit for requesting a magic sign-in link, keyed by client IP.

  Allows 10 requests per IP per 15 minutes (an office or venue NAT can host
  several members, so the IP limit is looser than the email limit).
  """
  @spec hit_magic_link_ip(:inet.ip_address() | String.t() | nil) ::
          {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_magic_link_ip(nil), do: {:allow, 0}

  def hit_magic_link_ip(ip_address) do
    hit("magic_link:ip:#{format_ip(ip_address)}", @fifteen_minutes_in_milliseconds, 10)
  end

  defp format_ip(ip_address) when is_binary(ip_address), do: ip_address

  defp format_ip(ip_address) when is_tuple(ip_address),
    do: ip_address |> :inet.ntoa() |> to_string()
end
