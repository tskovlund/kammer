defmodule KammerWeb.Plugs.RequireSetup do
  @moduledoc """
  Routes every request to the first-run wizard until setup completes
  (SPEC §13). Legal pages stay reachable (they may be legally required),
  as do the wizard itself, dev-only routes, and the newsletter
  unsubscribe confirm page — its POST twin bypasses this plug by
  pipeline (RFC 8058 must answer bare), so the GET stays symmetric:
  both give the same neutral 200 in every instance state (#239).
  """

  import Phoenix.Controller, only: [redirect: 2]
  import Plug.Conn

  @exempt_prefixes ["/setup", "/legal", "/dev", "/healthz", "/newsletter/unsubscribe"]

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
