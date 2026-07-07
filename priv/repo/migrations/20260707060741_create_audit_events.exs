defmodule Kammer.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :action, :string, null: false
      # A precomputed human-readable line (e.g. "made Alma an admin") —
      # the record must stay readable even after the target row it
      # describes is gone, so it never depends on a live join.
      add :summary, :text, null: false
      add :metadata, :map, null: false, default: %{}

      # Append-only: insert only, no updated_at. Microsecond precision
      # (unlike the rest of the schema) because several audit entries
      # can legitimately land within the same second and "newest
      # first" must stay a real order, not a tie Postgres breaks
      # arbitrarily.
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:audit_events, [:community_id, :inserted_at])
  end
end
