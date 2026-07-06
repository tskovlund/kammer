# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :kammer,
  ecto_repos: [Kammer.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Display name is a single constant so renaming is one commit (SPEC §15).
config :kammer, :product_name, "Kammer"

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
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ]

# Configure the endpoint
config :kammer, KammerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: KammerWeb.ErrorHTML, json: KammerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Kammer.PubSub,
  live_view: [signing_salt: "NYnzPZfx"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :kammer, Kammer.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  kammer: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  kammer: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
