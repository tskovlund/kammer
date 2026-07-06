defmodule KammerWeb.FileController do
  @moduledoc """
  Serves stored files with upload-hardening headers (SPEC §11): images
  (always re-encoded at upload) may render inline; everything else is
  forced to download with `Content-Disposition: attachment` and
  `X-Content-Type-Options: nosniff`. Access control runs through
  `Kammer.Files.fetch_accessible_file/2` → `Kammer.Authorization`.
  """

  use KammerWeb, :controller

  alias Kammer.Files
  alias Kammer.Files.StoredFile
  alias Kammer.Storage

  @doc "Serves the display version (inline for images, download otherwise)."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => file_id}) do
    serve(conn, file_id, fn stored_file -> stored_file.storage_key end, :auto)
  end

  @doc "Serves the thumbnail of an image."
  @spec thumbnail(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def thumbnail(conn, %{"id" => file_id}) do
    serve(conn, file_id, fn stored_file -> stored_file.thumbnail_key end, :thumbnail)
  end

  @doc "Serves the file as a forced download."
  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"id" => file_id}) do
    serve(conn, file_id, fn stored_file -> stored_file.storage_key end, :download)
  end

  defp serve(conn, file_id, key_fun, mode) do
    current_user = conn.assigns.current_scope && conn.assigns.current_scope.user

    with {:ok, %StoredFile{} = stored_file} <- Files.fetch_accessible_file(current_user, file_id),
         key when is_binary(key) <- key_fun.(stored_file) || :not_found,
         {:ok, path} <- Storage.path_for(key) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_disposition(stored_file, mode)
      |> put_resp_content_type(response_content_type(stored_file, mode))
      |> send_file(200, path)
    else
      {:error, :unauthorized} -> send_resp(conn, 404, "Not found")
      _not_found -> send_resp(conn, 404, "Not found")
    end
  end

  # Only re-encoded images are ever rendered inline from the app origin.
  defp put_disposition(conn, %StoredFile{kind: :image} = stored_file, mode)
       when mode in [:auto, :thumbnail] do
    put_resp_header(
      conn,
      "content-disposition",
      ~s(inline; filename="#{sanitize(stored_file.filename)}")
    )
  end

  defp put_disposition(conn, stored_file, _mode) do
    put_resp_header(
      conn,
      "content-disposition",
      ~s(attachment; filename="#{sanitize(stored_file.filename)}")
    )
  end

  defp response_content_type(%StoredFile{kind: :image}, :thumbnail), do: "image/webp"

  defp response_content_type(%StoredFile{kind: :image} = stored_file, _mode),
    do: stored_file.content_type

  defp response_content_type(stored_file, _mode), do: stored_file.content_type

  defp sanitize(filename), do: String.replace(filename, ~s("), "")
end
