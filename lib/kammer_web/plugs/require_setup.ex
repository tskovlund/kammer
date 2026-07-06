defmodule KammerWeb.Plugs.RequireSetup do
  @moduledoc """
  Routes every request to the first-run wizard until setup completes
  (SPEC §13). Legal pages stay reachable (they may be legally required),
  as do the wizard itself and dev-only routes.
  """

  import Phoenix.Controller, only: [redirect: 2]
  import Plug.Conn

  @exempt_prefixes ["/setup", "/legal", "/dev", "/healthz"]

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if exempt?(conn.request_path) or Kammer.Setup.completed?() do
      conn
    else
      conn
      |> redirect(to: "/setup")
      |> halt()
    end
  end

  defp exempt?(path) do
    Enum.any?(@exempt_prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  end
end
