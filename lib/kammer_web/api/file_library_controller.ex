defmodule KammerWeb.Api.FileLibraryController do
  @moduledoc """
  A group's file library over the API (RFC 0001, issue #181): browse
  folders and files, upload new files and new versions (ADR 0017), read
  version history, download, and — for managers — create/delete folders,
  set the read/write preset overrides (ADR 0009), and delete files and
  versions. Every decision is the context's: the controller resolves the
  addressed folder/file and hands `Kammer.Files` the actor, then maps the
  context's error tuples onto the one envelope — it adds transport, never
  policy.

  No-oracle, exactly as the feed (#156/#161) and events do: a folder or
  file the caller can't see answers 404 to every verb, indistinguishable
  from one that doesn't exist. A folder/file the caller *can* see but may
  not write/manage still 403s — that check runs on a resource whose
  existence is already known. The group file space is behind the files
  feature toggle (ADR 0016): a disabled space answers 404.
  """

  use KammerWeb, :controller

  alias Kammer.Authorization
  alias Kammer.Files
  alias Kammer.Files.Folder
  alias Kammer.Files.StoredFile
  alias Kammer.Repo
  alias KammerWeb.Api.GroupGate
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @override_fields ~w(read_override write_override)

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_files_group(conn, slug, group_slug, fn group, user ->
      with {:ok, folder} <- resolve_readable_folder(user, group, params["folder_id"]),
           {:ok, files} <- Files.list_files(user, group, folder) do
        relationship = Authorization.relationship(user, group)
        chain = Files.folder_chain(folder)
        subfolders = Files.list_folders(user, group, folder)

        json(conn, %{
          data: %{
            folder: folder && Serializer.folder(folder),
            chain: Enum.map(chain, &Serializer.folder/1),
            folders: Enum.map(subfolders, &Serializer.folder/1),
            files: files |> Repo.preload(:uploader_user) |> Enum.map(&Serializer.file(&1, user)),
            can_write: Authorization.can_write_folder?(user, group, chain, relationship),
            can_manage: Authorization.can_manage_files?(user, group, relationship)
          }
        })
      else
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"community_slug" => slug, "group_slug" => group_slug, "file_id" => file_id}) do
    with_files_group(conn, slug, group_slug, fn group, user ->
      with {:ok, file} <- fetch_group_file(user, group, file_id),
           {:ok, versions} <- Files.list_versions(user, file) do
        json(conn, %{data: Serializer.file(head_of(versions, file), user, versions)})
      else
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec upload(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upload(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_files_group(conn, slug, group_slug, fn group, user ->
      with {:ok, folder} <- resolve_readable_folder(user, group, params["folder_id"]),
           %Plug.Upload{} = upload <- fetch_upload(params),
           {:ok, stored_file} <-
             Files.upload_to_space(user, group, folder, upload.path, %{
               filename: upload.filename,
               content_type: upload.content_type
             }) do
        respond_uploaded(conn, user, stored_file)
      else
        {:error, :missing_file} -> ApiError.send(conn, :bad_request, "Send a `file` part.")
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec upload_version(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def upload_version(
        conn,
        %{
          "community_slug" => slug,
          "group_slug" => group_slug,
          "file_id" => file_id
        } = params
      ) do
    with_files_group(conn, slug, group_slug, fn group, user ->
      # A new version keeps the existing entry's name and folder, so
      # `upload_to_space` appends to it rather than creating a new entry
      # (ADR 0017) whatever the client names the part.
      with {:ok, file} <- fetch_group_file(user, group, file_id),
           entry_id when not is_nil(entry_id) <- file.file_entry_id,
           %Plug.Upload{} = upload <- fetch_upload(params),
           {:ok, stored_file} <-
             Files.upload_to_space(
               user,
               group,
               Files.get_folder(group, file.folder_id),
               upload.path,
               %{filename: file.filename, content_type: upload.content_type}
             ) do
        respond_uploaded(conn, user, stored_file)
      else
        nil -> ApiError.send(conn, :not_found, "Not found.")
        {:error, :missing_file} -> ApiError.send(conn, :bad_request, "Send a `file` part.")
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"community_slug" => slug, "group_slug" => group_slug, "file_id" => file_id}) do
    with_files_group(conn, slug, group_slug, fn group, user ->
      with {:ok, file} <- fetch_group_file(user, group, file_id),
           {:ok, deleted} <- Files.delete_file(user, file) do
        json(conn, %{data: Serializer.file(deleted, user)})
      else
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec delete_version(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete_version(conn, %{
        "community_slug" => slug,
        "group_slug" => group_slug,
        "file_id" => file_id,
        "version_id" => version_id
      }) do
    with_files_group(conn, slug, group_slug, fn group, user ->
      # The version must belong to the entry the path names; a mismatch
      # 404s exactly like a missing version — the id is only meaningful
      # within its file.
      with {:ok, file} <- fetch_group_file(user, group, file_id),
           entry_id when not is_nil(entry_id) <- file.file_entry_id,
           {:ok, version} <- fetch_group_file(user, group, version_id),
           ^entry_id <- version.file_entry_id,
           {:ok, deleted} <- Files.delete_version(user, version) do
        json(conn, %{data: Serializer.file_version(deleted, nil, user)})
      else
        nil -> ApiError.send(conn, :not_found, "Not found.")
        {:error, _reason} = error -> ApiError.from_result(conn, error)
        _mismatch -> ApiError.send(conn, :not_found, "Not found.")
      end
    end)
  end

  @spec create_folder(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_folder(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_files_group(conn, slug, group_slug, fn group, user ->
      with {:ok, parent} <- resolve_readable_folder(user, group, params["parent_folder_id"]),
           {:ok, folder} <- Files.create_folder(user, group, parent, params["name"] || "") do
        conn
        |> put_status(201)
        |> json(%{data: Serializer.folder(folder)})
      else
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec update_folder(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_folder(
        conn,
        %{
          "community_slug" => slug,
          "group_slug" => group_slug,
          "folder_id" => folder_id
        } = params
      ) do
    with_files_group(conn, slug, group_slug, fn group, user ->
      with {:ok, folder} <- resolve_readable_folder(user, group, folder_id),
           {:ok, updated} <-
             Files.update_folder_overrides(
               user,
               group,
               folder,
               Map.take(params, @override_fields)
             ) do
        json(conn, %{data: Serializer.folder(updated)})
      else
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec delete_folder(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete_folder(conn, %{
        "community_slug" => slug,
        "group_slug" => group_slug,
        "folder_id" => folder_id
      }) do
    with_files_group(conn, slug, group_slug, fn group, user ->
      with {:ok, folder} <- resolve_readable_folder(user, group, folder_id),
           {:ok, deleted} <- Files.delete_folder(user, group, folder) do
        json(conn, %{data: Serializer.folder(deleted)})
      else
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  ## Internals

  # Only a real multipart file part counts; anything else (a missing part,
  # or a `file` sent as a plain/empty text field) is `:missing_file` — a
  # clean 400, never a 500 from a bare string reaching the error envelope.
  defp fetch_upload(%{"file" => %Plug.Upload{} = upload}), do: upload
  defp fetch_upload(_params), do: {:error, :missing_file}

  # No-oracle (#156/#161, #339): a missing community, a missing group,
  # a group the caller may not even *view*, and a group with the files
  # feature off (ADR 0016) all fold into the same 404 via
  # `GroupGate.fetch/4` — never a 403 that would confirm a hidden
  # group's file space exists. The callback's own error tuples still
  # fall through to the one envelope.
  defp with_files_group(conn, community_slug, group_slug, fun) do
    user = conn.assigns.current_scope.user

    case GroupGate.fetch(user, community_slug, group_slug, feature: :files) do
      {:ok, _community, group} -> fun.(group, user)
      {:error, :not_found} -> ApiError.send(conn, :not_found, "Not found.")
    end
  end

  # The no-oracle read gate for a folder addressed by id: a missing or
  # unreadable folder both answer 404 (never revealing a restricted
  # folder exists). `nil` is the space root, always readable to a caller
  # who can see the group.
  defp resolve_readable_folder(_user, _group, folder_id) when folder_id in [nil, ""],
    do: {:ok, nil}

  defp resolve_readable_folder(user, group, folder_id) do
    case Files.get_folder(group, folder_id) do
      nil ->
        {:error, :not_found}

      %Folder{} = folder ->
        relationship = Authorization.relationship(user, group)
        chain = Files.folder_chain(folder)

        if Authorization.can_read_folder?(user, group, chain, relationship),
          do: {:ok, folder},
          else: {:error, :not_found}
    end
  end

  # Fetch a stored file the caller may read that lives in this group's
  # space. `fetch_accessible_file`'s `:unauthorized` (hidden) becomes
  # `:not_found` here — the no-oracle boundary — and a file from another
  # scope is treated as missing.
  defp fetch_group_file(user, group, file_id) do
    with {:ok, %StoredFile{} = file} <- readable_or_missing(user, file_id),
         true <- file.group_id == group.id do
      {:ok, file}
    else
      _hidden_or_foreign -> {:error, :not_found}
    end
  end

  defp readable_or_missing(user, file_id) do
    case Files.fetch_accessible_file(user, file_id) do
      {:error, :unauthorized} -> {:error, :not_found}
      other -> other
    end
  end

  # A freshly uploaded file is the entry's current (newest) version, so
  # the version history carries its uploader preloaded — respond from the
  # head of that list so `uploaded_by` is populated.
  defp respond_uploaded(conn, user, %StoredFile{} = stored_file) do
    versions =
      case Files.list_versions(user, stored_file) do
        {:ok, list} -> list
        _error -> []
      end

    conn
    |> put_status(201)
    |> json(%{data: Serializer.file(head_of(versions, stored_file), user, versions)})
  end

  defp head_of([%StoredFile{} = current | _rest], _fallback), do: current
  defp head_of(_versions, fallback), do: fallback
end
