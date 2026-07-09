defmodule Kammer.Application do
  @moduledoc """
  OTP application entry point: supervises the repo, PubSub, Oban, and the
  web endpoint.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    # Fail the boot on an unparseable TRUSTED_PROXIES value
    # (issue #162) instead of 500ing on the first request.
    KammerWeb.ClientIp.validate_config!()

    children = [
      KammerWeb.Telemetry,
      Kammer.Repo,
      {DNSCluster, query: Application.get_env(:kammer, :dns_cluster_query) || :ignore},
      {Oban, Application.fetch_env!(:kammer, Oban)},
      Kammer.RateLimit,
      {Phoenix.PubSub, name: Kammer.PubSub}
    ]

    children =
      children ++
        setup_children() ++
        [
          # Start to serve requests, typically the last entry
          KammerWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kammer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # First-run setup (SPEC §13): apply env-provided settings and print the
  # setup token. Skipped in tests (the SQL sandbox owns the connection).
  # Runs synchronously during supervisor start (issue #98): an invalid
  # env-provided setting raises, and that raise must fail the boot — a
  # fire-and-forget Task's crash would only be logged, leaving the app
  # up with the bad value silently dropped. Placed before the endpoint,
  # so requests are never served with env settings not yet applied.
  defp setup_children do
    if Application.get_env(:kammer, :setup_on_boot, true) do
      [
        %{
          id: Kammer.Setup,
          start: {Kammer.Setup, :start_boot, []},
          restart: :temporary
        }
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl Application
  def config_change(changed, _new, removed) do
    KammerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
