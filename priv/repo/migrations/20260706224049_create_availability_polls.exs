defmodule Kammer.Repo.Migrations.CreateAvailabilityPolls do
  use Ecto.Migration

  def change do
    create table(:availability_polls, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :title, :string, null: false
      add :closed_at, :utc_datetime

      # The event the winning date became; nilified if that event is
      # later deleted — the closed poll remains as a record.
      add :converted_event_id, references(:events, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:availability_polls, [:group_id, :closed_at])

    create table(:availability_options, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :poll_id, references(:availability_polls, type: :binary_id, on_delete: :delete_all),
        null: false

      add :starts_at, :utc_datetime, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:availability_options, [:poll_id])

    create table(:availability_responses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :option_id,
          references(:availability_options, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :answer, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:availability_responses, [:option_id, :user_id])
  end
end
