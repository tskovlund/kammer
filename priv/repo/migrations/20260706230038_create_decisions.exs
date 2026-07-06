defmodule Kammer.Repo.Migrations.CreateDecisions do
  use Ecto.Migration

  def change do
    create table(:decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      # The motion post carries the text and the vote; deleting the
      # post deletes the register entry with it (and vice versa via UI).
      add :post_id, references(:posts, type: :binary_id, on_delete: :delete_all), null: false

      add :title, :string, null: false
      add :outcome, :string
      add :outcome_note, :text
      add :decided_at, :utc_datetime
      add :decided_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:decisions, [:post_id])
    create index(:decisions, [:group_id, :inserted_at])
  end
end
