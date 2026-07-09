import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kammer start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :kammer, KammerWeb.Endpoint, server: true
end

config :kammer, KammerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# CORS for the JSON API (issue #150): wildcard unless restricted to a
# comma-separated origin list, e.g.
# API_ALLOWED_ORIGINS=https://app.example.org,https://club.example.org
# Skipped in test: the suite asserts both modes and must not inherit
# whatever the developer's shell happens to export.
if config_env() != :test do
  allowed_origins =
    "API_ALLOWED_ORIGINS"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  # An empty/blank value stays unset (wildcard) — never deny-all.
  if allowed_origins != [] do
    config :kammer, :api_allowed_origins, allowed_origins
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :kammer, Kammer.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :kammer, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Bind IPv4-any by default: hosts and containers with IPv6 disabled
  # fail to boot on the dual-stack `::` bind (:eafnosupport). Set
  # PHX_LISTEN_IPV6=true for a dual-stack listener.
  listen_ip =
    if System.get_env("PHX_LISTEN_IPV6") in ~w(true 1),
      do: {0, 0, 0, 0, 0, 0, 0, 0},
      else: {0, 0, 0, 0}

  config :kammer, KammerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: listen_ip],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :kammer, KammerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :kammer, KammerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Mailer (SPEC §1: Swoosh, configurable SMTP/provider adapters).
  #
  # SMTP is the universal default for self-hosters. Provider API adapters
  # can be added by setting MAILER_ADAPTER (currently: "smtp" | "local").
  mailer_adapter = System.get_env("MAILER_ADAPTER", "smtp")

  case mailer_adapter do
    "smtp" ->
      smtp_relay =
        System.get_env("SMTP_HOST") ||
          raise """
          environment variable SMTP_HOST is missing (or set MAILER_ADAPTER=local
          for a no-op mailbox during evaluation).

          Kammer signs users in with magic links, so working outbound email
          is required. See .env.example for the SMTP_* variables.
          """

      config :kammer, Kammer.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: smtp_relay,
        port: String.to_integer(System.get_env("SMTP_PORT", "587")),
        username: System.get_env("SMTP_USERNAME"),
        password: System.get_env("SMTP_PASSWORD"),
        ssl: System.get_env("SMTP_SSL") in ~w(true 1),
        tls: :if_available,
        auth: :if_available,
        retries: 1

    "local" ->
      # Dev-style in-memory mailbox; useful for evaluating without SMTP.
      # Swoosh only starts the mailbox process when :local is true (prod.exs
      # disables it for real adapters), so re-enable it here.
      config :kammer, Kammer.Mailer, adapter: Swoosh.Adapters.Local
      config :swoosh, local: true

    other ->
      raise "unsupported MAILER_ADAPTER #{inspect(other)} (expected \"smtp\" or \"local\")"
  end

  # ## File storage (SPEC §1: local disk default, S3-compatible optional)
  case System.get_env("STORAGE_ADAPTER", "local") do
    "local" ->
      config :kammer, :storage_adapter, Kammer.Storage.Local

      config :kammer,
             :uploads_path,
             System.get_env("UPLOADS_PATH", "/app/uploads")

    "s3" ->
      config :kammer, :storage_adapter, Kammer.Storage.S3

      config :kammer, :s3,
        endpoint: System.get_env("S3_ENDPOINT"),
        bucket: System.fetch_env!("S3_BUCKET"),
        access_key_id: System.fetch_env!("S3_ACCESS_KEY_ID"),
        secret_access_key: System.fetch_env!("S3_SECRET_ACCESS_KEY"),
        region: System.get_env("S3_REGION", "us-east-1")

    other ->
      raise "unsupported STORAGE_ADAPTER #{inspect(other)} (expected \"local\" or \"s3\")"
  end

  config :kammer,
         :upload_max_megabytes,
         String.to_integer(System.get_env("UPLOAD_MAX_MB", "100"))

  # ## Web Push (SPEC §1: VAPID). Optional — push is disabled without keys.
  if vapid_private_key = System.get_env("VAPID_PRIVATE_KEY") do
    config :web_push_ex, :vapid,
      private_key: vapid_private_key,
      public_key: System.fetch_env!("VAPID_PUBLIC_KEY"),
      subject:
        System.get_env(
          "VAPID_SUBJECT",
          "mailto:#{System.get_env("MAIL_FROM_ADDRESS", "kammer@" <> host)}"
        )
  end

  config :kammer, :mail_from,
    address: System.get_env("MAIL_FROM_ADDRESS", "kammer@#{host}"),
    name: System.get_env("MAIL_FROM_NAME", "Kammer")

  # ## Scheduled backups (SPEC §14). Opt-in: without BACKUP_DIR the
  # nightly job is a no-op — see docs/backups.md.
  if backup_dir = System.get_env("BACKUP_DIR") do
    config :kammer, :backup,
      dir: backup_dir,
      keep: String.to_integer(System.get_env("BACKUP_KEEP", "14")),
      age_recipient: System.get_env("BACKUP_AGE_RECIPIENT")
  end

  # ## Admin update notice (SPEC §13). Opt-out, so this is set
  # unconditionally — the default without DISABLE_UPDATE_CHECK is on.
  config :kammer, :update_check, enabled: System.get_env("DISABLE_UPDATE_CHECK") not in ~w(true 1)
end
