defmodule Kammer.Repo.Migrations.CreateFileEntries do
  use Ecto.Migration

  def up do
    # Versioned files (issue #15): the logical file (name, place,
    # permissions target) splits from the blob. Every version stays a
    # stored_files row; the entry points at the current one.
    create table(:file_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all)
      add :folder_id, references(:folders, type: :binary_id, on_delete: :delete_all)
      add :name, :string, null: false
      add :current_version_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create index(:file_entries, [:community_id, :group_id, :folder_id])

    alter table(:stored_files) do
      add :file_entry_id, references(:file_entries, type: :binary_id, on_delete: :delete_all)
    end

    create index(:stored_files, [:file_entry_id])

    # current_version_id is a forward reference to stored_files — added
    # after both tables exist to avoid a circular create.
    execute """
    ALTER TABLE file_entries
    ADD CONSTRAINT file_entries_current_version_id_fkey
    FOREIGN KEY (current_version_id) REFERENCES stored_files(id) ON DELETE SET NULL
    """

    # Backfill: every deliberate file-space file becomes a one-version
    # entry. Feed attachments (post_attachments) and transient uploads
    # stay entry-less — they are artifacts of posts, not documents.
    execute """
    INSERT INTO file_entries
      (id, community_id, group_id, folder_id, name, current_version_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), sf.community_id, sf.group_id, sf.folder_id, sf.filename, sf.id,
           sf.inserted_at, sf.updated_at
    FROM stored_files sf
    WHERE sf.transient_expires_at IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM post_attachments pa WHERE pa.stored_file_id = sf.id
      )
    """

    execute """
    UPDATE stored_files sf
    SET file_entry_id = fe.id
    FROM file_entries fe
    WHERE fe.current_version_id = sf.id
    """
  end

  def down do
    alter table(:stored_files) do
      remove :file_entry_id
    end

    drop table(:file_entries)
  end
end
