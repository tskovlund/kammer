defmodule Kammer.Repo.Migrations.CreateEventSeries do
  use Ecto.Migration

  def change do
    create table(:event_series, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :frequency, :string, null: false
      add :until, :date, null: false

      timestamps(type: :utc_datetime)
    end

    # Occurrences are ordinary `events` rows sharing a `series_id` — no
    # separate occurrence table, so RSVPs/slots/comments/ICS/reminders
    # need no changes at all. `cancelled_at` is the per-instance
    # override (SPEC §6): still viewable, excluded from listings/
    # reminders/feeds. Nilify on series delete: deleting the series row
    # (not a user-facing action today) must not cascade-delete real
    # event history.
    alter table(:events) do
      add :series_id, references(:event_series, type: :binary_id, on_delete: :nilify_all)
      add :cancelled_at, :utc_datetime
    end

    create index(:events, [:series_id])
  end
end
