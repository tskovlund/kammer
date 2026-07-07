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
  alias Kammer.Files.FileEntry
  alias Kammer.Files.Folder
  alias Kammer.Files.StoredFile
  alias Kammer.Groups.Group
  alias Kammer.Media
  alias Kammer.RateLimit
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

    folder_id =
      cond do
        transient_expires_at -> nil
        folder = Keyword.get(opts, :folder) -> folder.id
        true -> feed_uploads_folder(group).id
      end

    base_attrs = %{
      "filename" => sanitize_filename(filename),
      "community_id" => group.community_id,
      "group_id" => group.id,
      "folder_id" => folder_id,
      "uploader_user_id" => uploader.id,
      "transient_expires_at" => transient_expires_at
    }

    with :ok <- check_upload_rate_limit(uploader.id),
         :ok <- check_quota(group, source_path) do
      if Media.image_content_type?(declared_content_type) do
        store_image(source_path, base_attrs)
      else
        store_plain_file(source_path, declared_content_type, base_attrs)
      end
    end
  end

  @doc """
  Uploads into a specific folder of a file space (community or group),
  enforcing the write presets and quota.
  """
  @spec upload_to_space(User.t(), Community.t() | Group.t(), Folder.t() | nil, Path.t(), map()) ::
          {:ok, StoredFile.t()} | {:error, term()}
  def upload_to_space(%User{} = uploader, scope, folder, source_path, file_info) do
    relationship = Authorization.relationship(uploader, scope)
    folder_chain = folder_chain(folder)

    with :ok <- check_upload_rate_limit(uploader.id),
         :ok <- files_feature_gate(scope),
         true <-
           Authorization.can_write_folder?(uploader, scope, folder_chain, relationship) ||
             :unauthorized,
         :ok <- check_quota(scope, source_path) do
      declared_content_type = Map.get(file_info, :content_type, "application/octet-stream")

      {community_id, group_id} =
        case scope do
          %Group{} = group -> {group.community_id, group.id}
          %Community{} = community -> {community.id, nil}
        end

      sanitized_filename = sanitize_filename(Map.fetch!(file_info, :filename))

      base_attrs = %{
        "filename" => sanitized_filename,
        "community_id" => community_id,
        "group_id" => group_id,
        "folder_id" => folder && folder.id,
        "uploader_user_id" => uploader.id
      }

      # Issue #15: uploading the same name into the same place is a new
      # VERSION of the existing entry, not a duplicate — the Drive-like
      # semantics users already expect. New names create new entries.
      Repo.transact(fn ->
        entry = get_or_create_entry(scope, folder, sanitized_filename)
        base_attrs = Map.put(base_attrs, "file_entry_id", entry.id)

        store_result =
          if Media.image_content_type?(declared_content_type) do
            store_image(source_path, base_attrs)
          else
            store_plain_file(source_path, declared_content_type, base_attrs)
          end

        with {:ok, stored_file} <- store_result do
          entry =
            entry
            |> Ecto.Changeset.change(current_version_id: stored_file.id)
            |> Repo.update!()

          prune_versions(scope, entry)
          {:ok, %StoredFile{stored_file | file_entry: entry}}
        end
      end)
    else
      :unauthorized -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_or_create_entry(scope, folder, name) do
    {community_id, group_id} =
      case scope do
        %Group{} = group -> {group.community_id, group.id}
        %Community{} = community -> {community.id, nil}
      end

    folder_id = folder && folder.id

    existing =
      Repo.one(
        from(entry in FileEntry,
          where: entry.community_id == ^community_id,
          where: ^scope_group_condition(group_id),
          where: ^entry_folder_condition(folder_id),
          where: entry.name == ^name
        )
      )

    existing ||
      Repo.insert!(
        FileEntry.create_changeset(%FileEntry{}, %{
          name: name,
          community_id: community_id,
          group_id: group_id,
          folder_id: folder_id
        })
      )
  end

  defp scope_group_condition(nil), do: dynamic([entry], is_nil(entry.group_id))
  defp scope_group_condition(group_id), do: dynamic([entry], entry.group_id == ^group_id)

  defp entry_folder_condition(nil), do: dynamic([entry], is_nil(entry.folder_id))
  defp entry_folder_condition(folder_id), do: dynamic([entry], entry.folder_id == ^folder_id)

  # Issue #15: NULL retention = unlimited. Otherwise keep the newest N
  # versions; pruned blobs leave storage and the quota alike.
  defp prune_versions(scope, %FileEntry{} = entry) do
    case scope_retention(scope) do
      nil ->
        :ok

      keep when is_integer(keep) and keep > 0 ->
        entry
        |> versions_query()
        |> offset(^keep)
        |> Repo.all()
        |> Enum.each(&delete_version_record/1)
    end
  end

  defp scope_retention(%Group{version_retention: retention}), do: retention
  defp scope_retention(%Community{version_retention: retention}), do: retention

  defp versions_query(%FileEntry{id: entry_id}) do
    from(stored_file in StoredFile,
      where: stored_file.file_entry_id == ^entry_id,
      order_by: [desc: stored_file.version_seq]
    )
  end

  defp delete_version_record(%StoredFile{} = version) do
    Storage.delete(version.storage_key)
    if version.thumbnail_key, do: Storage.delete(version.thumbnail_key)
    Repo.delete!(version)
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

      with {:ok, stored_file} <-
             %StoredFile{} |> StoredFile.create_changeset(attrs) |> Repo.insert() do
        enqueue_text_extraction(stored_file)
        {:ok, stored_file}
      end
    end
  end

  defp enqueue_text_extraction(%StoredFile{} = stored_file) do
    %{"stored_file_id" => stored_file.id}
    |> Kammer.Workers.FileTextExtractionWorker.new()
    |> Oban.insert()
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

  ## Folders (SPEC §7: shallow tree, presets only — ADR 0009)

  @doc """
  The system "Feed uploads" folder of a group, created on first use
  (SPEC §5: feed attachments default here).
  """
  @spec feed_uploads_folder(Group.t()) :: Folder.t()
  def feed_uploads_folder(%Group{} = group) do
    Repo.get_by(Folder, group_id: group.id, system_key: "feed_uploads") ||
      Repo.insert!(
        %Folder{
          community_id: group.community_id,
          group_id: group.id,
          name: "Feed uploads",
          system_key: "feed_uploads"
        },
        on_conflict: :nothing,
        conflict_target:
          {:unsafe_fragment,
           "(group_id, system_key) WHERE system_key IS NOT NULL AND group_id IS NOT NULL"}
      ) ||
      Repo.get_by!(Folder, group_id: group.id, system_key: "feed_uploads")
  end

  @doc """
  The readable folders directly under `parent_folder` (nil = space root),
  applying read presets through `Kammer.Authorization`.
  """
  @spec list_folders(User.t() | nil, Community.t() | Group.t(), Folder.t() | nil) :: [Folder.t()]
  def list_folders(actor, scope, parent_folder \\ nil) do
    relationship = Authorization.relationship(actor, scope)
    parent_chain = folder_chain(parent_folder)

    scope
    |> folders_in_scope_query(parent_folder)
    |> Repo.all()
    |> Enum.filter(fn folder ->
      Authorization.can_read_folder?(actor, scope, parent_chain ++ [folder], relationship)
    end)
  end

  defp folders_in_scope_query(%Group{} = group, parent_folder) do
    from(folder in Folder,
      where: folder.group_id == ^group.id,
      where: ^parent_condition(parent_folder),
      order_by: folder.name
    )
  end

  defp folders_in_scope_query(%Community{} = community, parent_folder) do
    from(folder in Folder,
      where: folder.community_id == ^community.id and is_nil(folder.group_id),
      where: ^parent_condition(parent_folder),
      order_by: folder.name
    )
  end

  defp parent_condition(nil), do: dynamic([folder], is_nil(folder.parent_folder_id))

  defp parent_condition(%Folder{id: parent_id}),
    do: dynamic([folder], folder.parent_folder_id == ^parent_id)

  @doc """
  Files directly in `folder` (nil = space root) the actor may read.
  """
  @spec list_files(User.t() | nil, Community.t() | Group.t(), Folder.t() | nil) ::
          {:ok, [StoredFile.t()]} | {:error, :unauthorized}
  def list_files(actor, scope, folder \\ nil) do
    relationship = Authorization.relationship(actor, scope)
    chain = folder_chain(folder)

    if Authorization.can_read_folder?(actor, scope, chain, relationship) do
      {:ok,
       scope
       |> files_in_scope_query(folder)
       |> Repo.all()}
    else
      {:error, :unauthorized}
    end
  end

  defp files_in_scope_query(%Group{} = group, folder) do
    from(stored_file in StoredFile,
      where: stored_file.group_id == ^group.id,
      where: is_nil(stored_file.transient_expires_at),
      where: ^file_folder_condition(folder),
      order_by: stored_file.filename
    )
    |> current_versions_only()
  end

  defp files_in_scope_query(%Community{} = community, folder) do
    from(stored_file in StoredFile,
      where: stored_file.community_id == ^community.id and is_nil(stored_file.group_id),
      where: is_nil(stored_file.transient_expires_at),
      where: ^file_folder_condition(folder),
      order_by: stored_file.filename
    )
    |> current_versions_only()
  end

  @doc """
  Restricts a `StoredFile` query to only current file-entry versions —
  old versions never appear in listings or search (entry-less rows,
  e.g. feed uploads, are unaffected).
  """
  @spec current_versions_only(Ecto.Query.t()) :: Ecto.Query.t()
  def current_versions_only(query) do
    from(stored_file in query,
      left_join: entry in FileEntry,
      on: entry.id == stored_file.file_entry_id,
      where: is_nil(stored_file.file_entry_id) or entry.current_version_id == stored_file.id
    )
  end

  @doc """
  Every folder in a community — both the community space and every
  group's — for building an in-memory folder tree (`Kammer.Search`
  uses this to check the read-override invariant against a batch of
  candidate files without one query per file).
  """
  @spec list_all_folders(Community.t()) :: [Folder.t()]
  def list_all_folders(%Community{} = community) do
    Repo.all(from folder in Folder, where: folder.community_id == ^community.id)
  end

  defp file_folder_condition(nil), do: dynamic([stored_file], is_nil(stored_file.folder_id))

  defp file_folder_condition(%Folder{id: folder_id}),
    do: dynamic([stored_file], stored_file.folder_id == ^folder_id)

  @doc """
  Creates a folder (write access at the parent; depth-limited — the tree
  stays shallow).
  """
  @spec create_folder(User.t(), Community.t() | Group.t(), Folder.t() | nil, String.t()) ::
          {:ok, Folder.t()} | {:error, term()}
  def create_folder(%User{} = actor, scope, parent_folder, name) do
    relationship = Authorization.relationship(actor, scope)
    parent_chain = folder_chain(parent_folder)

    cond do
      files_feature_gate(scope) != :ok ->
        {:error, :not_found}

      not Authorization.can_write_folder?(actor, scope, parent_chain, relationship) ->
        {:error, :unauthorized}

      length(parent_chain) >= Folder.maximum_depth() ->
        {:error, :too_deep}

      true ->
        {community_id, group_id} =
          case scope do
            %Group{} = group -> {group.community_id, group.id}
            %Community{} = community -> {community.id, nil}
          end

        %Folder{}
        |> Folder.changeset(%{
          "name" => name,
          "community_id" => community_id,
          "group_id" => group_id,
          "parent_folder_id" => parent_folder && parent_folder.id
        })
        |> Repo.insert()
    end
  end

  @doc """
  Sets a folder's read/write preset overrides (admins only; overrides can
  only restrict — ADR 0009).
  """
  @spec update_folder_overrides(User.t(), Community.t() | Group.t(), Folder.t(), map()) ::
          {:ok, Folder.t()} | {:error, term()}
  def update_folder_overrides(%User{} = actor, scope, %Folder{} = folder, attrs) do
    relationship = Authorization.relationship(actor, scope)

    if Authorization.can_manage_files?(actor, scope, relationship) do
      folder
      |> Ecto.Changeset.cast(attrs, [:read_override, :write_override])
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Deletes a folder (admins only). Subfolders are removed; files fall back
  to the space root (never deleted — files outlive their folders).
  """
  @spec delete_folder(User.t(), Community.t() | Group.t(), Folder.t()) ::
          {:ok, Folder.t()} | {:error, term()}
  def delete_folder(%User{} = actor, scope, %Folder{} = folder) do
    relationship = Authorization.relationship(actor, scope)

    cond do
      not Authorization.can_manage_files?(actor, scope, relationship) -> {:error, :unauthorized}
      folder.system_key != nil -> {:error, :system_folder}
      true -> Repo.delete(folder)
    end
  end

  @doc """
  Deletes a file: the uploader may remove their own; admins any.
  The stored bytes are deleted too.
  """
  @spec delete_file(User.t(), StoredFile.t()) :: {:ok, StoredFile.t()} | {:error, :unauthorized}
  def delete_file(%User{} = actor, %StoredFile{} = stored_file) do
    scope = scope_of(stored_file)
    relationship = Authorization.relationship(actor, scope)

    if stored_file.uploader_user_id == actor.id or
         Authorization.can_manage_files?(actor, scope, relationship) do
      case stored_file.file_entry_id do
        nil ->
          delete_version_record(stored_file)
          {:ok, stored_file}

        entry_id ->
          # Deleting the file deletes the entry and all its versions
          # (issue #15) — blobs first, then the entry cascades the rows.
          entry = Repo.get!(FileEntry, entry_id)
          entry |> versions_query() |> Repo.all() |> Enum.each(&delete_version_record/1)
          Repo.delete!(entry)
          {:ok, stored_file}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  The version history of a file (issue #15): newest first, visible to
  everyone who can read the file itself. Entry-less files have none.
  """
  @spec list_versions(User.t() | nil, StoredFile.t()) ::
          {:ok, [StoredFile.t()]} | {:error, :unauthorized}
  def list_versions(_actor, %StoredFile{file_entry_id: nil}), do: {:ok, []}

  def list_versions(actor, %StoredFile{} = stored_file) do
    scope = scope_of(stored_file)
    relationship = Authorization.relationship(actor, scope)
    folder = stored_file.folder_id && Repo.get(Folder, stored_file.folder_id)
    chain = folder_chain(folder)

    if Authorization.can_read_folder?(actor, scope, chain, relationship) do
      entry = Repo.get!(FileEntry, stored_file.file_entry_id)
      {:ok, entry |> versions_query() |> preload(:uploader_user) |> Repo.all()}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Deletes a single version (issue #15): its own uploader or file
  managers; never the last remaining version — that is `delete_file`.
  Deleting the current version repoints the entry to the newest
  remaining one.
  """
  @spec delete_version(User.t(), StoredFile.t()) ::
          {:ok, StoredFile.t()} | {:error, :unauthorized | :last_version}
  def delete_version(%User{} = actor, %StoredFile{file_entry_id: entry_id} = version)
      when not is_nil(entry_id) do
    scope = scope_of(version)
    relationship = Authorization.relationship(actor, scope)

    cond do
      version.uploader_user_id != actor.id and
          not Authorization.can_manage_files?(actor, scope, relationship) ->
        {:error, :unauthorized}

      Repo.aggregate(from(sf in StoredFile, where: sf.file_entry_id == ^entry_id), :count) <= 1 ->
        {:error, :last_version}

      true ->
        Repo.transact(fn ->
          entry = Repo.get!(FileEntry, entry_id)
          delete_version_record(version)

          if entry.current_version_id == version.id do
            newest = entry |> versions_query() |> limit(1) |> Repo.one!()

            entry
            |> Ecto.Changeset.change(current_version_id: newest.id)
            |> Repo.update!()
          end

          {:ok, version}
        end)
    end
  end

  @doc """
  The full ancestor chain of a folder, root-first (inclusive).
  """
  @spec folder_chain(Folder.t() | nil) :: [Folder.t()]
  def folder_chain(nil), do: []

  def folder_chain(%Folder{} = folder) do
    build_chain(folder, [folder], Folder.maximum_depth() + 1)
  end

  defp build_chain(_folder, chain, 0), do: chain

  defp build_chain(%Folder{parent_folder_id: nil}, chain, _remaining), do: chain

  defp build_chain(%Folder{parent_folder_id: parent_id}, chain, remaining) do
    case Repo.get(Folder, parent_id) do
      nil -> chain
      parent -> build_chain(parent, [parent | chain], remaining - 1)
    end
  end

  @doc """
  Loads a folder within a scope, or `nil`.
  """
  @spec get_folder(Community.t() | Group.t(), Ecto.UUID.t() | nil) :: Folder.t() | nil
  def get_folder(_scope, nil), do: nil

  def get_folder(scope, folder_id) do
    case Ecto.UUID.cast(folder_id) do
      {:ok, _uuid} ->
        case scope do
          %Group{} = group ->
            Repo.get_by(Folder, id: folder_id, group_id: group.id)

          %Community{} = community ->
            Repo.one(
              from(folder in Folder,
                where:
                  folder.id == ^folder_id and folder.community_id == ^community.id and
                    is_nil(folder.group_id)
              )
            )
        end

      :error ->
        nil
    end
  end

  ## Auto-collections (SPEC §7)

  @doc """
  The "Images" auto-collection: every readable image in the scope.
  Folder read restrictions are honored per file.
  """
  @spec list_image_collection(User.t() | nil, Community.t() | Group.t()) :: [StoredFile.t()]
  def list_image_collection(actor, scope) do
    list_collection(actor, scope, dynamic([stored_file], stored_file.kind == :image))
  end

  @doc """
  The "Posted in feed" auto-collection: files attached to posts.
  """
  @spec list_feed_collection(User.t() | nil, Community.t() | Group.t()) :: [StoredFile.t()]
  def list_feed_collection(actor, scope) do
    attached_ids =
      from(attachment in Kammer.Feed.PostAttachment, select: attachment.stored_file_id)

    list_collection(
      actor,
      scope,
      dynamic([stored_file], stored_file.id in subquery(attached_ids))
    )
  end

  defp list_collection(actor, scope, condition) do
    relationship = Authorization.relationship(actor, scope)

    scope_condition =
      case scope do
        %Group{} = group ->
          dynamic([stored_file], stored_file.group_id == ^group.id)

        %Community{} = community ->
          dynamic(
            [stored_file],
            stored_file.community_id == ^community.id and is_nil(stored_file.group_id)
          )
      end

    from(stored_file in StoredFile,
      where: ^scope_condition,
      where: ^condition,
      where: is_nil(stored_file.transient_expires_at),
      order_by: [desc: stored_file.inserted_at]
    )
    |> Repo.all()
    |> Enum.filter(fn stored_file ->
      chain = stored_file.folder_id && folder_chain(Repo.get(Folder, stored_file.folder_id))
      Authorization.can_read_folder?(actor, scope, chain || [], relationship)
    end)
  end

  ## Storage policy (SPEC §7: unmetered or quota mode)

  @doc """
  Bytes used by a scope's file space.
  """
  @spec space_usage_bytes(Community.t() | Group.t()) :: non_neg_integer()
  def space_usage_bytes(%Group{} = group) do
    Repo.one(
      from(stored_file in StoredFile,
        where: stored_file.group_id == ^group.id,
        select: type(coalesce(sum(stored_file.byte_size), 0), :integer)
      )
    )
  end

  def space_usage_bytes(%Community{} = community) do
    Repo.one(
      from(stored_file in StoredFile,
        where: stored_file.community_id == ^community.id and is_nil(stored_file.group_id),
        select: type(coalesce(sum(stored_file.byte_size), 0), :integer)
      )
    )
  end

  @doc """
  Per-user contribution stats for a scope (SPEC §7: shown in either
  storage-policy mode), largest first.
  """
  @spec contribution_stats(Community.t() | Group.t()) :: [
          %{user: User.t() | nil, bytes: non_neg_integer()}
        ]
  def contribution_stats(scope) do
    scope_condition =
      case scope do
        %Group{} = group ->
          dynamic([stored_file], stored_file.group_id == ^group.id)

        %Community{} = community ->
          dynamic(
            [stored_file],
            stored_file.community_id == ^community.id and is_nil(stored_file.group_id)
          )
      end

    Repo.all(
      from(stored_file in StoredFile,
        where: ^scope_condition,
        left_join: user in assoc(stored_file, :uploader_user),
        group_by: user.id,
        select: %{user: user, bytes: type(coalesce(sum(stored_file.byte_size), 0), :integer)},
        order_by: [desc: coalesce(sum(stored_file.byte_size), 0)]
      )
    )
  end

  @doc """
  The scope's effective quota in bytes, or `nil` when unmetered.
  """
  @spec effective_quota_bytes(Community.t() | Group.t()) :: non_neg_integer() | nil
  def effective_quota_bytes(scope) do
    settings = Kammer.Communities.get_instance_settings()

    if settings.storage_policy == :quota do
      scope.storage_quota_bytes
    end
  end

  # ADR 0016: the files toggle hides the GROUP file space. Community
  # spaces have no toggle, and feed attachments (auto-collections) keep
  # working — the feed is not toggleable.
  defp files_feature_gate(%Group{} = group), do: Authorization.feature_gate(group, :files)
  defp files_feature_gate(%Community{}), do: :ok

  defp check_upload_rate_limit(uploader_id) do
    case RateLimit.hit_upload(uploader_id) do
      {:allow, _count} -> :ok
      {:deny, _retry} -> {:error, :rate_limited}
    end
  end

  defp check_quota(scope, source_path) do
    case effective_quota_bytes(scope) do
      nil ->
        :ok

      quota_bytes ->
        upload_size = File.stat!(source_path).size

        if space_usage_bytes(scope) + upload_size > quota_bytes do
          {:error, :quota_exceeded}
        else
          :ok
        end
    end
  end

  defp scope_of(%StoredFile{group_id: nil} = stored_file) do
    Repo.get!(Community, stored_file.community_id)
  end

  defp scope_of(%StoredFile{group_id: group_id}) do
    Repo.get!(Group, group_id)
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
