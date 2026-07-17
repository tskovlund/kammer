defmodule Kammer.MixProject do
  use Mix.Project

  def project do
    [
      app: :kammer,
      # The single source of truth for the product version (issue
      # #204). Runtime code reads it via `Kammer.version/0`; the PWA
      # reports it by fetching `GET /api/v1/instance`. Kept as an
      # inline quoted literal on this line — release.yml greps for it
      # to verify the tag. The `-dev` marker drops at the first tagged
      # release (`v0.1.0`, docs/release.md).
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix, :ex_unit]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Kammer.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.8"},
      {:hammer, "~> 7.0"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.3"},
      {:tz, "~> 0.28"},
      {:oban, "~> 2.23"},
      {:mdex, "~> 0.13"},
      # Optional: lets restricted environments build the MDEx NIF from
      # source (MDEX_BUILD=1) instead of fetching the precompiled binary.
      {:rustler, ">= 0.0.0", optional: true},
      {:vix, "~> 0.40"},
      {:web_push_ex, "~> 0.2.0"},
      {:req, "~> 0.5"},
      # OpenAPI contract for the JSON API (ADR 0014): the spec is
      # generated from the same modules that serve requests, so the
      # Svelte/Swift/Kotlin clients generate from a contract that
      # cannot drift.
      {:open_api_spex, "~> 3.21"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      # Passkeys (SPEC §16, ADR 0003): WebAuthn registration + assertion
      # verification. Published on Hex as `wax_` (trailing underscore —
      # `wax` was already taken).
      {:wax_, "~> 0.7"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # Code quality and security tooling (SPEC §17)
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.3", only: [:dev, :test]}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "hooks.install"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      lint: ["format --check-formatted", "credo --strict"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        # Stale committed .pot/.po references slipped through twice in
        # #239's review rounds — extraction is a generated artifact and
        # gets the same stay-in-sync gate as the rest (run
        # `mix gettext.extract --merge` when this fails).
        "gettext.extract --check-up-to-date",
        "test"
      ]
    ]
  end
end
