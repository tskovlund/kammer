defmodule Kammer.Application do
  @moduledoc """
  OTP application entry point: supervises the repo, PubSub, Oban, and the
  web endpoint.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      KammerWeb.Telemetry,
      Kammer.Repo,
      {DNSCluster, query: Application.get_env(:kammer, :dns_cluster_query) || :ignore},
      {Oban, Application.fetch_env!(:kammer, Oban)},
      {Phoenix.PubSub, name: Kammer.PubSub},
      # Start to serve requests, typically the last entry
      KammerWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kammer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl Application
  def config_change(changed, _new, removed) do
    KammerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
