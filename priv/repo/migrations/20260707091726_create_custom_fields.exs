defmodule Kammer.Repo.Migrations.CreateCustomFields do
  use Ecto.Migration

  def change do
    create table(:custom_fields, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :label, :string, null: false
      add :field_type, :string, null: false
      add :options, {:array, :string}, default: []
      add :visibility, :string, null: false, default: "members"
      add :required, :boolean, null: false, default: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:custom_fields, [:community_id, :position])

    create table(:custom_field_values, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :custom_field_id, references(:custom_fields, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :value, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:custom_field_values, [:custom_field_id, :user_id])
  end
end
