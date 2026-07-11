defmodule Kammer.RateLimit do
  @moduledoc """
  Central rate limiter (SPEC §11): magic-link issuance (per email and per
  IP), signup, posting/commenting, guest endpoints, uploads, @everyone, and
  email-change confirmation all take their limits from here so policy lives
  in one place.

  Backed by Hammer's ETS backend — per-node counters, which is sufficient
  for the single-node deployment model of v1.
  """

  use Hammer, backend: :ets

  alias Kammer.Config

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

  @doc """
  Rate limit for redeeming a short sign-in code (issue #177), keyed by
  the email the attempt targets: 5 attempts per address per 15 minutes.

  This is the brute-force backstop: codes carry 40 bits of entropy, so
  5 guesses per code lifetime leaves a worst-case success chance of
  about 5 in 2^40. Every attempt counts — valid or not — so guessing
  burns the budget before a later correct guess can land.
  """
  @spec hit_login_code_email(String.t()) :: {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_login_code_email(email) when is_binary(email) do
    # String.downcase and citext's lower() can disagree on exotic
    hit(
      # Unicode, giving such an address a marginally fresh limiter key —
      # the handful of variants keeps the guess budget far below the
      # 40-bit code space, so this matches hit_magic_link_email's
      # existing normalization rather than chasing exact citext folding.
      "login_code:email:#{String.downcase(email)}",
      @fifteen_minutes_in_milliseconds,
      5
    )
  end

  @doc """
  Rate limit for redeeming a short sign-in code, keyed by client IP:
  20 attempts per 15 minutes — looser than the email limit for shared
  venue networks, but still stops one address from spraying codes
  across many emails.
  """
  @spec hit_login_code_ip(:inet.ip_address() | String.t() | nil) ::
          {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_login_code_ip(nil), do: {:allow, 0}

  def hit_login_code_ip(ip_address) do
    hit("login_code:ip:#{format_ip(ip_address)}", @fifteen_minutes_in_milliseconds, 20)
  end

  @doc """
  Rate limit for guest interaction requests (RSVP confirmations and the
  like), keyed by email. Same budget as magic links — both send email.
  """
  @spec hit_guest_email(String.t()) :: {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_guest_email(email) when is_binary(email) do
    hit("guest:email:#{String.downcase(email)}", @fifteen_minutes_in_milliseconds, 3)
  end

  @doc """
  Rate limit for guest interaction requests, keyed by client IP — looser,
  like the magic-link IP limit, for shared venue networks.
  """
  @spec hit_guest_ip(:inet.ip_address() | String.t() | nil) ::
          {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_guest_ip(nil), do: {:allow, 0}

  def hit_guest_ip(ip_address) do
    hit("guest:ip:#{format_ip(ip_address)}", @fifteen_minutes_in_milliseconds, 10)
  end

  @doc """
  Rate limit for `@everyone` broadcast mentions, keyed by group (SPEC
  §5: gated and rate-limited). A throughput/policy limit (ADR 0027) —
  configurable via `RATE_LIMIT_EVERYONE_MENTIONS_PER_HOUR`, default 2
  per group per hour.
  """
  @spec hit_everyone_mention(Ecto.UUID.t()) :: {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_everyone_mention(group_id) do
    hit(
      "everyone_mention:group:#{group_id}",
      60 * 60 * 1000,
      Config.rate_limit_everyone_mentions_per_hour()
    )
  end

  @doc """
  Rate limit for account creation, keyed by client IP: 10 per hour —
  looser than the magic-link IP limit since it's a one-time action per
  person, but still caps mass-account creation from one address.
  """
  @spec hit_signup_ip(:inet.ip_address() | String.t() | nil) ::
          {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_signup_ip(nil), do: {:allow, 0}

  def hit_signup_ip(ip_address) do
    hit("signup:ip:#{format_ip(ip_address)}", 60 * 60 * 1000, 10)
  end

  @doc """
  Rate limit for creating a post, keyed by author. A throughput/policy
  limit (ADR 0027) — configurable via `RATE_LIMIT_POSTS_PER_5MIN`,
  default 10 per 5 minutes.
  """
  @spec hit_post_create(Ecto.UUID.t()) :: {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_post_create(user_id) do
    hit("post_create:user:#{user_id}", 5 * 60 * 1000, Config.rate_limit_posts_per_5min())
  end

  @doc """
  Rate limit for creating a comment, keyed by author. Shared across
  post/event/assignment comments — one "commenting" budget per
  person, not per subject type. A throughput/policy limit (ADR 0027)
  — configurable via `RATE_LIMIT_COMMENTS_PER_5MIN`, default 20 per 5
  minutes.
  """
  @spec hit_comment_create(Ecto.UUID.t()) :: {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_comment_create(user_id) do
    hit("comment_create:user:#{user_id}", 5 * 60 * 1000, Config.rate_limit_comments_per_5min())
  end

  @doc """
  Rate limit for uploading a file, keyed by uploader — generous enough
  to attach a batch of images to one post. A throughput/policy limit
  (ADR 0027) — configurable via `RATE_LIMIT_UPLOADS_PER_10MIN`,
  default 40 per 10 minutes.
  """
  @spec hit_upload(Ecto.UUID.t()) :: {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_upload(user_id) do
    hit("upload:user:#{user_id}", 10 * 60 * 1000, Config.rate_limit_uploads_per_10min())
  end

  @doc """
  Rate limit for email-change confirmation emails, keyed by the acting
  user: 5 per hour.

  Unlike the magic-link limiter, the key is the requesting user, not the
  recipient. The confirmation goes to a user-supplied *new* address, so
  keying on the (attacker-varied) target would hand every fresh address
  its own budget and throttle nothing; capping per user is what stops one
  account from looping the change-email form into an arbitrary-recipient
  email relay (issue #97). Five per hour absorbs an honest mistype-and-
  correct while holding the relay to a trickle.
  """
  @spec hit_email_change(Ecto.UUID.t()) :: {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_email_change(user_id) do
    hit("email_change:user:#{user_id}", 60 * 60 * 1000, 5)
  end

  @doc """
  Rate limit for issuing email invites, keyed by the acting community/
  group admin: 20 per hour (issue #97). Only email-bearing invites
  count — a link invite sends nothing — so this caps how fast one
  privileged actor can drive branded email to arbitrary addresses,
  the same arbitrary-recipient-flood class every other email path here
  already throttles. Generous enough to onboard a whole board in one
  sitting, tight enough that the endpoint can't become a spam relay.
  """
  @spec hit_invite_issuance(Ecto.UUID.t()) :: {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_invite_issuance(user_id) do
    hit("invite_issuance:user:#{user_id}", 60 * 60 * 1000, 20)
  end

  @doc """
  Rate limit for filing moderation reports, keyed by reporter: 20 per
  hour. An anti-abuse backstop (ADR 0027 tier 3 — fixed, no config
  knob): the queue is the moderators' shared attention budget, and one
  person filing more than 20 reports an hour is flooding it, not
  moderating. Every attempt counts — duplicate reports burn the budget
  too, like the sign-in code limiter.
  """
  @spec hit_report_create(Ecto.UUID.t()) :: {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_report_create(user_id) do
    hit("report_create:user:#{user_id}", 60 * 60 * 1000, 20)
  end

  @doc """
  Rate limit for completing first-run setup, keyed by client IP: 10 per
  hour, the same fixed budget as `hit_signup_ip/1`. This is defense-in-
  depth for the pre-setup window — the setup token printed to the
  server logs is already the real gate — but that window has no
  operator yet around to notice or react to abuse, so the limit is a
  fixed constant with no runtime config knob (a security limit behind
  config is a footgun).
  """
  @spec hit_setup_ip(:inet.ip_address() | String.t() | nil) ::
          {:allow, non_neg_integer()} | {:deny, timeout()}
  def hit_setup_ip(nil), do: {:allow, 0}

  def hit_setup_ip(ip_address) do
    hit("setup:ip:#{format_ip(ip_address)}", 60 * 60 * 1000, 10)
  end

  defp format_ip(ip_address) when is_binary(ip_address), do: ip_address

  defp format_ip(ip_address) when is_tuple(ip_address),
    do: ip_address |> :inet.ntoa() |> to_string()
end
