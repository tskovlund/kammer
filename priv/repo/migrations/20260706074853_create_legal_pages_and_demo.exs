defmodule Kammer.Repo.Migrations.CreateLegalPagesAndDemo do
  use Ecto.Migration

  def change do
    create table(:legal_pages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :content_markdown, :text, null: false, default: ""
      add :updated_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:legal_pages, [:key])

    alter table(:instance_settings) do
      add :demo_community_id, references(:communities, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
