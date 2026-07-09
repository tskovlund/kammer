defmodule Kammer.Repo.Migrations.ReleaseFolderContentsOnFolderDelete do
  @moduledoc """
  Deleting a folder must release its files to the space root, never
  delete them — the documented `Files.delete_folder/3` semantics
  ("files outlive their folders"). The original `:delete_all` on
  `file_entries.folder_id` contradicted that, and worse: Postgres's
  SET NULL trigger on `stored_files.folder_id` re-validates the row's
  `file_entry_id` reference after the entry's cascade delete, so any
  folder holding a file raised a foreign-key error instead of
  deleting at all (surfaced by the API folder-deletion test, #208).
  """

  use Ecto.Migration

  def change do
    alter table(:file_entries) do
      modify :folder_id, references(:folders, type: :binary_id, on_delete: :nilify_all),
        from: references(:folders, type: :binary_id, on_delete: :delete_all)
    end
  end
end
