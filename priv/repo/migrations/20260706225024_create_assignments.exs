defmodule Kammer.Repo.Migrations.CreateAssignments do
  use Ecto.Migration

  def change do
    create table(:assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :title, :string, null: false
      add :notes_markdown, :text
      add :due_at, :utc_datetime

      add :completed_at, :utc_datetime
      add :completed_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:assignments, [:group_id, :completed_at])

    # Multi-claimant by design (#17: "multiple persons assigned
    # simultaneously") — one row per person, no capacity.
    create table(:assignment_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :assignment_id, references(:assignments, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:assignment_claims, [:assignment_id, :user_id])

    # Third subject for the one comment engine (ADR 0007).
    alter table(:comments) do
      add :assignment_id, references(:assignments, type: :binary_id, on_delete: :delete_all)
    end

    create index(:comments, [:assignment_id, :inserted_at])

    execute(
      "ALTER TABLE comments DROP CONSTRAINT comment_subject_exactly_one",
      "ALTER TABLE comments ADD CONSTRAINT comment_subject_exactly_one CHECK ((post_id IS NOT NULL AND event_id IS NULL) OR (post_id IS NULL AND event_id IS NOT NULL))"
    )

    execute(
      "ALTER TABLE comments ADD CONSTRAINT comment_subject_exactly_one CHECK (num_nonnulls(post_id, event_id, assignment_id) = 1)",
      "ALTER TABLE comments DROP CONSTRAINT comment_subject_exactly_one"
    )
  end
end
