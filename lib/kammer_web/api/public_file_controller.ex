defmodule KammerWeb.Api.PublicFileController do
  @moduledoc """
  Post attachments over the tokenless public surface (issue #185 slice
  B): the public twin of the Bearer-authenticated `Api.FileController`
  routes — same bytes and hardening headers via `KammerWeb.FileServing`
  — but authorized through `Kammer.Files.fetch_public_file/1` instead
  of an actor's scope access: a file is servable here only when it's
  an attachment on a post an anonymous visitor can already read via
  `PublicController.post/2` (published, not pending approval, not
  deleted) whose group additionally passes
  `Kammer.Authorization.publicly_readable?/1`. Everything else —
  group/community file-space files not attached to any visible post,
  orphaned uploads, anything in a private/community/sealed/archived
  group — 404s exactly like a nonexistent id (no existence oracle,
  issue #156/#161).
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
    case FileServing.serve_public(conn, file_id, mode) do
      {:ok, conn} -> conn
      {:error, :not_found} -> ApiError.send(conn, :not_found, "Not found.")
    end
  end
end
