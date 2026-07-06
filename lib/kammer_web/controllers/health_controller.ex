defmodule KammerWeb.HealthController do
  @moduledoc """
  Liveness endpoint for container orchestration: verifies the database
  connection and answers `ok`.
  """

  use KammerWeb, :controller

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    Kammer.Repo.query!("SELECT 1")
    text(conn, "ok")
  end
end
