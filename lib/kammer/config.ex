defmodule Kammer.Config do
  @moduledoc """
  Accessor home for every tier-2 deployment-config value (ADR 0027,
  issue #234): operator-tunable throughput/policy rate limits, token
  lifetimes, and retention windows. Each is set once at boot from an
  env var (`config/runtime.exs`, bounds-validated, raises on an
  invalid value naming the var), with a safe compiled-in default
  applied when the var is unset — the default lives here exactly
  once, never re-typed at a call site or in `runtime.exs`.

  Distinct from `Kammer.RateLimit`'s fixed anti-abuse/security limits
  (magic-link, login-code, signup, setup, email-change, invite
  issuance) — those are named constants on purpose, per ADR 0027: a
  security backstop behind a runtime knob is a footgun. Only the
  throughput/policy limits (post, comment, upload creation;
  `@everyone` mention cadence) are configurable here.
  """

  @doc """
  Posts a single author may create per 5 minutes (`RATE_LIMIT_POSTS_PER_5MIN`,
  default 10, bounds 1-100).
  """
  @spec rate_limit_posts_per_5min() :: pos_integer()
  def rate_limit_posts_per_5min do
    Application.get_env(:kammer, :rate_limit_posts_per_5min, 10)
  end

  @doc """
  Comments a single author may create per 5 minutes
  (`RATE_LIMIT_COMMENTS_PER_5MIN`, default 20, bounds 1-200). Shared
  across post/event/assignment comments — one "commenting" budget.
  """
  @spec rate_limit_comments_per_5min() :: pos_integer()
  def rate_limit_comments_per_5min do
    Application.get_env(:kammer, :rate_limit_comments_per_5min, 20)
  end

  @doc """
  Files a single uploader may register per 10 minutes
  (`RATE_LIMIT_UPLOADS_PER_10MIN`, default 40, bounds 1-200).
  """
  @spec rate_limit_uploads_per_10min() :: pos_integer()
  def rate_limit_uploads_per_10min do
    Application.get_env(:kammer, :rate_limit_uploads_per_10min, 40)
  end

  @doc """
  `@everyone` broadcast mentions a single group may receive per hour
  (`RATE_LIMIT_EVERYONE_MENTIONS_PER_HOUR`, default 2, bounds 1-20).
  """
  @spec rate_limit_everyone_mentions_per_hour() :: pos_integer()
  def rate_limit_everyone_mentions_per_hour do
    Application.get_env(:kammer, :rate_limit_everyone_mentions_per_hour, 2)
  end

  @doc """
  How long a browser session token stays valid (`SESSION_VALIDITY_DAYS`,
  default 14, bounds 1-90).
  """
  @spec session_validity_days() :: pos_integer()
  def session_validity_days do
    Application.get_env(:kammer, :session_validity_days, 14)
  end

  @doc """
  How long an API device token stays valid (ADR 0014)
  (`API_DEVICE_VALIDITY_DAYS`, default 365, bounds 1-1825).
  """
  @spec api_device_validity_days() :: pos_integer()
  def api_device_validity_days do
    Application.get_env(:kammer, :api_device_validity_days, 365)
  end

  @doc """
  How long an email-change confirmation token stays valid
  (`CHANGE_EMAIL_VALIDITY_DAYS`, default 7, bounds 1-30).
  """
  @spec change_email_validity_days() :: pos_integer()
  def change_email_validity_days do
    Application.get_env(:kammer, :change_email_validity_days, 7)
  end

  @doc """
  How long a device's step-up (recent re-authentication, issue #294,
  ADR 0029) stays fresh, in minutes (`STEP_UP_VALIDITY_MINUTES`,
  default 10, bounds 1-60).
  """
  @spec step_up_validity_minutes() :: pos_integer()
  def step_up_validity_minutes do
    Application.get_env(:kammer, :step_up_validity_minutes, 10)
  end

  @doc """
  Days after soft-delete before a post/comment's content is purged
  (SPEC §5) (`CONTENT_RETENTION_DAYS`, default 30, bounds 1-365).
  """
  @spec content_retention_days() :: pos_integer()
  def content_retention_days do
    Application.get_env(:kammer, :content_retention_days, 30)
  end

  @doc """
  Days before a transient (non-file-space) upload auto-expires
  (SPEC §5) (`TRANSIENT_UPLOAD_DAYS`, default 30, bounds 1-90).
  """
  @spec transient_upload_days() :: pos_integer()
  def transient_upload_days do
    Application.get_env(:kammer, :transient_upload_days, 30)
  end

  @doc """
  How long a guest confirm link stays valid, in hours
  (`GUEST_CONFIRM_LINK_HOURS`, default 48, bounds 1-336).
  """
  @spec guest_confirm_link_hours() :: pos_integer()
  def guest_confirm_link_hours do
    Application.get_env(:kammer, :guest_confirm_link_hours, 48)
  end

  @doc """
  How long a guest management link stays valid, in days
  (`GUEST_MANAGE_LINK_DAYS`, default 60, bounds 1-365).
  """
  @spec guest_manage_link_days() :: pos_integer()
  def guest_manage_link_days do
    Application.get_env(:kammer, :guest_manage_link_days, 60)
  end

  @doc """
  Parses and bounds-validates an integer environment variable (the
  #98 boot-validation pattern — mirrors `KammerWeb.ClientIp`'s
  `validate_config!/0`): `nil` when `env_var` is unset, so the
  caller leaves the app-env key unset and the accessor's compiled-in
  default applies; the parsed integer when it is set and within
  `[min, max]`; raises `ArgumentError` naming `env_var` and the bad
  value otherwise, so an operator typo fails the boot instead of
  silently clamping or being dropped.

  Called from `config/runtime.exs` to build every tier-2 numeric
  setting — kept here, rather than inlined there, so the validation
  itself is unit-testable.
  """
  @spec parse_bounded_env_int!(String.t(), integer(), integer()) :: integer() | nil
  def parse_bounded_env_int!(env_var, min, max) do
    case System.get_env(env_var) do
      nil ->
        nil

      raw ->
        case Integer.parse(raw) do
          {int, ""} when int >= min and int <= max ->
            int

          _ ->
            raise ArgumentError,
                  "environment variable #{env_var} must be an integer between #{min} and #{max}, got: #{inspect(raw)}"
        end
    end
  end
end
