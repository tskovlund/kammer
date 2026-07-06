defmodule Kammer.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :title, :string, null: false
      add :description_markdown, :text
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime
      add :all_day, :boolean, null: false, default: false
      add :timezone, :string, null: false, default: "Etc/UTC"
      add :location_name, :string
      add :location_url, :string
      add :comment_locked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:events, [:group_id, :starts_at])
    create index(:events, [:community_id, :starts_at])

    create table(:event_rsvps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:event_rsvps, [:event_id, :user_id])

    alter table(:comments) do
      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all)
      modify :post_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    create index(:comments, [:event_id, :inserted_at])

    create constraint(:comments, :comment_subject_exactly_one,
             check:
               "(post_id IS NOT NULL AND event_id IS NULL) OR (post_id IS NULL AND event_id IS NOT NULL)"
           )

    alter table(:users) do
      add :ics_token, :string
    end

    create unique_index(:users, [:ics_token])

    alter table(:groups) do
      add :ics_token, :string
    end

    create unique_index(:groups, [:ics_token])
  end
end
