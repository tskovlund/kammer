defmodule KammerWeb.FileController do
  @moduledoc """
  Serves stored files to browser sessions. The actual serving —
  hardening headers, disposition, authorization through
  `Kammer.Files.fetch_accessible_file/2` — lives in
  `KammerWeb.FileServing`, shared with the Bearer-authenticated API
  file routes.
  """

  use KammerWeb, :controller

  alias KammerWeb.FileServing

  @doc "Serves the display version (inline for images, download otherwise)."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => file_id}), do: serve(conn, file_id, :auto)

  @doc "Serves the thumbnail of an image."
  @spec thumbnail(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def thumbnail(conn, %{"id" => file_id}), do: serve(conn, file_id, :thumbnail)

  @doc "Serves the file as a forced download."
  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"id" => file_id}), do: serve(conn, file_id, :download)

  defp serve(conn, file_id, mode) do
    current_user = conn.assigns.current_scope && conn.assigns.current_scope.user

    case FileServing.serve(conn, current_user, file_id, mode) do
      {:ok, conn} -> conn
      {:error, :not_found} -> send_resp(conn, 404, "Not found")
    end
  end
end
