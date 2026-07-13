# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :kammer, :scopes,
  user: [
    default: true,
    module: Kammer.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: Kammer.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :kammer,
  ecto_repos: [Kammer.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Timezone-aware rendering (SPEC §1: stored UTC, rendered per user).
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Display name is a single constant so renaming is one commit (SPEC §15).
config :kammer, :product_name, "Kammer"

# Where the instance-served Svelte PWA is mounted (ADR 0024, issue
# #176/#187). The LiveView removal cut flipped this from "/app" to "/":
# the PWA is now the only web UI. This one key is read at compile time
# by the endpoint's Plug.Static mount and the router's catch-all scope
# (defined LAST, so at "/" it can't shadow /api, /healthz or the feeds);
# it is kept in lockstep with `paths.base` in clients/web/vite.config.ts
# and the icon/start_url paths in clients/web/static/manifest.webmanifest.
config :kammer, :pwa_base_path, "/"

# Where the endpoint's Plug.Static reads the built client from.
# Test env points this at a committed fixture so the static-serving
# path (only:-list, immutable caching) is genuinely exercised.
config :kammer, :pwa_static_root, {:kammer, "priv/static/app"}

# i18n: English and Danish complete for everything shipped (SPEC §1).
config :kammer, KammerWeb.Gettext, allowed_locales: ["en", "da"], default_locale: "en"

# Background jobs (SPEC §1: digests, reminders, backups, transient expiry,
# media processing, scheduled publishing).
config :kammer, Oban,
  engine: Oban.Engines.Basic,
  repo: Kammer.Repo,
  queues: [default: 10, media: 5, mailers: 10, scheduled: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       {"30 3 * * *", Kammer.Workers.PurgeDeletedContentWorker},
       # No-op unless BACKUP_DIR is configured (SPEC §14).
       {"15 4 * * *", Kammer.Workers.BackupWorker},
       # Delivers only to users who opted in (digest_frequency).
       {"0 6 * * *", Kammer.Workers.DigestWorker},
       # Guest newsletter digests — offset from the member digest tick.
       {"15 6 * * *", Kammer.Workers.NewsletterDigestWorker},
       # No-op if DISABLE_UPDATE_CHECK is set (SPEC §13).
       {"0 5 * * *", Kammer.Workers.UpdateCheckWorker}
     ]}
  ]

# Configure the endpoint
config :kammer, KammerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: KammerWeb.ErrorHTML, json: KammerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Kammer.PubSub

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :kammer, Kammer.Mailer, adapter: Swoosh.Adapters.Local

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
