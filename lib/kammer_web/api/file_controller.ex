defmodule KammerWeb.Api.FileController do
  @moduledoc """
  Stored files over the API (issue #178): the same bytes, hardening
  headers, and authorization as the browser file routes — via
  `KammerWeb.FileServing` — but Bearer-authenticated, so API clients
  can render post attachments without a browser session. Invisible and
  nonexistent files both answer 404 (no existence oracle).
  """

  use KammerWeb, :controller

  alias KammerWeb.ApiError
  alias KammerWeb.FileServing

  @doc "Serves the display version (inline for images, download otherwise)."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"file_id" => file_id}), do: serve(conn, file_id, :auto)

  @doc "Serves the thumbnail of an image."
  @spec thumbnail(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def thumbnail(conn, %{"file_id" => file_id}), do: serve(conn, file_id, :thumbnail)

  @doc "Serves the file as a forced download."
  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"file_id" => file_id}), do: serve(conn, file_id, :download)

  defp serve(conn, file_id, mode) do
    # Authed bytes stay out of shared caches (#315) — belt-and-braces
    # over RFC 9111's Authorization rule. Set before `serve/4`, which
    # sends the file and can't take a header afterwards. (The tokenless
    # `PublicFileController` twin deliberately omits this — those
    # attachments are public and cacheable.)
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    case FileServing.serve(conn, conn.assigns.current_scope.user, file_id, mode) do
      {:ok, conn} -> conn
      {:error, :not_found} -> ApiError.send(conn, :not_found, "Not found.")
    end
  end
end
