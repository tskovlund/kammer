defmodule Kammer.Repo.Migrations.CreateFoldersAndStoragePolicy do
  use Ecto.Migration

  def change do
    create table(:folders, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all)
      add :parent_folder_id, references(:folders, type: :binary_id, on_delete: :delete_all)
      add :name, :string, null: false
      add :read_override, :string, null: false, default: "inherit"
      add :write_override, :string, null: false, default: "inherit"
      add :system_key, :string

      timestamps(type: :utc_datetime)
    end

    create index(:folders, [:community_id])
    create index(:folders, [:group_id])
    create index(:folders, [:parent_folder_id])

    create unique_index(:folders, [:group_id, :system_key],
             where: "system_key IS NOT NULL AND group_id IS NOT NULL",
             name: :folders_group_system_key_index
           )

    alter table(:stored_files) do
      add :folder_id, references(:folders, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:stored_files, [:folder_id])

    alter table(:instance_settings) do
      add :storage_policy, :string, null: false, default: "unmetered"
    end

    alter table(:communities) do
      add :storage_quota_bytes, :bigint
    end

    alter table(:groups) do
      add :storage_quota_bytes, :bigint
    end
  end
end
