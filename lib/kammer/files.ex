defmodule Kammer.Files do
  @moduledoc """
  Stored files (SPEC §7 — the feed slice): registering uploads with
  hardening (images re-encoded via `Kammer.Media`, everything else
  served download-only), transient attachments with auto-expiry, and
  authorized retrieval. Folder trees, permission preset overrides, and
  quotas arrive with the files build step; the visibility baseline —
  a file is visible exactly to those who can view its owning scope —
  is enforced here from day one through `Kammer.Authorization`.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Authorization
  alias Kammer.Communities.Community
  alias Kammer.Files.StoredFile
  alias Kammer.Groups.Group
  alias Kammer.Media
  alias Kammer.Repo
  alias Kammer.Storage

  @default_transient_days 30
  @default_upload_limit_megabytes 100

  @doc "Upload size limit in bytes (configurable, SPEC §7 default 100 MB)."
  @spec upload_limit_bytes() :: pos_integer()
  def upload_limit_bytes do
    megabytes =
      Application.get_env(:kammer, :upload_max_megabytes, @default_upload_limit_megabytes)

    megabytes * 1024 * 1024
  end

  @doc """
  Registers an uploaded file into a group's file space (feed uploads,
  SPEC §5). Images are re-encoded and thumbnailed before storage; other
  files are stored as-is and always served as downloads (SPEC §11).

  Options:

    * `:transient` — no file-space home; auto-expires after
      #{@default_transient_days} days (SPEC §5).
  """
  @spec create_from_upload(User.t(), Group.t(), Path.t(), map(), keyword()) ::
          {:ok, StoredFile.t()} | {:error, term()}
  def create_from_upload(%User{} = uploader, %Group{} = group, source_path, file_info, opts \\ []) do
    filename = Map.fetch!(file_info, :filename)
    declared_content_type = Map.get(file_info, :content_type, "application/octet-stream")

    transient_expires_at =
      if Keyword.get(opts, :transient, false) do
        DateTime.add(DateTime.utc_now(:second), @default_transient_days, :day)
      end

    base_attrs = %{
      "filename" => sanitize_filename(filename),
      "community_id" => group.community_id,
      "group_id" => group.id,
      "uploader_user_id" => uploader.id,
      "transient_expires_at" => transient_expires_at
    }

    if Media.image_content_type?(declared_content_type) do
      store_image(source_path, base_attrs)
    else
      store_plain_file(source_path, declared_content_type, base_attrs)
    end
  end

  defp store_image(source_path, base_attrs) do
    with {:ok, processed} <- Media.process_image(source_path),
         display_key = Storage.generate_key(".jpg"),
         thumbnail_key = Storage.generate_key(".webp"),
         :ok <- Storage.put(display_key, processed.display_path),
         :ok <- Storage.put(thumbnail_key, processed.thumbnail_path) do
      attrs =
        Map.merge(base_attrs, %{
          "content_type" => processed.content_type,
          "byte_size" => File.stat!(processed.display_path).size,
          "storage_key" => display_key,
          "thumbnail_key" => thumbnail_key,
          "kind" => "image",
          "width" => processed.width,
          "height" => processed.height,
          "processed_at" => DateTime.utc_now(:second)
        })

      %StoredFile{} |> StoredFile.create_changeset(attrs) |> Repo.insert()
    end
  end

  defp store_plain_file(source_path, declared_content_type, base_attrs) do
    extension = base_attrs |> Map.fetch!("filename") |> Path.extname() |> String.slice(0, 10)
    storage_key = Storage.generate_key(extension)

    with :ok <- Storage.put(storage_key, source_path) do
      attrs =
        Map.merge(base_attrs, %{
          "content_type" => safe_content_type(declared_content_type),
          "byte_size" => File.stat!(source_path).size,
          "storage_key" => storage_key,
          "kind" => "file"
        })

      %StoredFile{} |> StoredFile.create_changeset(attrs) |> Repo.insert()
    end
  end

  @doc """
  Fetches a file the actor may access, or an error. The rule is the
  visibility baseline (SPEC §7): group files inherit the group's
  visibility; community files require community membership.
  """
  @spec fetch_accessible_file(User.t() | nil, Ecto.UUID.t()) ::
          {:ok, StoredFile.t()} | {:error, :not_found | :unauthorized}
  def fetch_accessible_file(actor, file_id) do
    case Repo.get(StoredFile, file_id) do
      nil ->
        {:error, :not_found}

      %StoredFile{group_id: nil} = stored_file ->
        community = Repo.get!(Community, stored_file.community_id)

        with :ok <- Authorization.authorize(actor, :view_community, community) do
          {:ok, stored_file}
        end

      %StoredFile{} = stored_file ->
        group = Repo.get!(Group, stored_file.group_id)

        with :ok <- Authorization.authorize(actor, :view_group, group) do
          {:ok, stored_file}
        end
    end
  end

  @doc """
  Deletes transient files past their expiry (SPEC §5). Returns the purge
  count. Invoked by the scheduled Oban worker.
  """
  @spec purge_expired_transient_files() :: non_neg_integer()
  def purge_expired_transient_files do
    now = DateTime.utc_now(:second)

    expired_files =
      Repo.all(
        from(stored_file in StoredFile,
          where: stored_file.transient_expires_at <= ^now
        )
      )

    Enum.each(expired_files, fn stored_file ->
      Storage.delete(stored_file.storage_key)
      if stored_file.thumbnail_key, do: Storage.delete(stored_file.thumbnail_key)
      Repo.delete(stored_file)
    end)

    length(expired_files)
  end

  defp sanitize_filename(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^\w.\- ]/u, "_")
    |> String.slice(0, 255)
  end

  # SVGs and anything script-capable must never be served inline from the
  # app origin (SPEC §11); the file controller forces download for
  # kind: :file, so keeping the declared type is safe — but normalize
  # blatantly dangerous inline types anyway.
  defp safe_content_type(content_type) do
    case String.downcase(content_type) do
      "text/html" <> _rest -> "application/octet-stream"
      "application/xhtml" <> _rest -> "application/octet-stream"
      other -> String.slice(other, 0, 100)
    end
  end
end
