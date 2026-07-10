defmodule KammerWeb.FileServing do
  @moduledoc """
  Serves stored files with upload-hardening headers (SPEC §11): images
  (always re-encoded at upload) may render inline; everything else is
  forced to download with `Content-Disposition: attachment` and
  `X-Content-Type-Options: nosniff`. Access control runs through
  `Kammer.Files.fetch_accessible_file/2` → `Kammer.Authorization`.

  Shared by the browser `FileController` (session auth), the API
  `Api.FileController` (Bearer auth), and the API `Api.PublicFileController`
  (tokenless, issue #185 slice B) — same bytes, same headers; only the
  credential, the authorization check, and the error body differ.
  """

  import Plug.Conn

  alias Kammer.Accounts.User
  alias Kammer.Files
  alias Kammer.Files.StoredFile
  alias Kammer.Storage

  @type mode() :: :auto | :thumbnail | :download

  @doc """
  Serves the file to the conn, or `{:error, :not_found}` — one answer
  for "doesn't exist" and "not yours to see" (no existence oracle).
  """
  @spec serve(Plug.Conn.t(), User.t() | nil, String.t(), mode()) ::
          {:ok, Plug.Conn.t()} | {:error, :not_found}
  def serve(conn, actor, file_id, mode) do
    with {:ok, %StoredFile{} = stored_file} <- Files.fetch_accessible_file(actor, file_id) do
      respond(conn, stored_file, mode)
    else
      _unauthorized_or_missing -> {:error, :not_found}
    end
  end

  @doc """
  Serves the file over the tokenless public surface (issue #185 slice
  B): same bytes and headers as `serve/4`, but authorized through
  `Kammer.Files.fetch_public_file/1` instead of an actor's scope
  access — a file is servable here only when it's an attachment on a
  post an anonymous visitor can already read publicly (see that
  function's doc), never merely because its owning scope is publicly
  viewable.
  """
  @spec serve_public(Plug.Conn.t(), String.t(), mode()) ::
          {:ok, Plug.Conn.t()} | {:error, :not_found}
  def serve_public(conn, file_id, mode) do
    with {:ok, %StoredFile{} = stored_file} <- Files.fetch_public_file(file_id) do
      respond(conn, stored_file, mode)
    else
      _not_found -> {:error, :not_found}
    end
  end

  defp respond(conn, stored_file, mode) do
    with key when is_binary(key) <- storage_key(stored_file, mode) || :not_found,
         {:ok, path} <- Storage.path_for(key) do
      conn =
        conn
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_disposition(stored_file, mode)
        |> put_resp_content_type(response_content_type(stored_file, mode))
        |> send_file(200, path)

      {:ok, conn}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp storage_key(stored_file, :thumbnail), do: stored_file.thumbnail_key
  defp storage_key(stored_file, _mode), do: stored_file.storage_key

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
  defp response_content_type(stored_file, _mode), do: stored_file.content_type

  defp sanitize(filename), do: String.replace(filename, ~s("), "")
end
