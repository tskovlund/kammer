defmodule Kammer.Repo.Migrations.AddLockVersionToLegalPages do
  use Ecto.Migration

  # Optimistic concurrency for operator legal-page edits (#276 item 4): a
  # published row carries a version an editor echoes back, so a stale write
  # (another operator saved first) is refused with a 409 rather than silently
  # last-write-winning. Existing rows backfill to 1; the unpersisted built-in
  # template reports 0 (the schema default), keeping published rows strictly
  # ahead of the template so a concurrent first publish can't match-and-clobber.
  def change do
    alter table(:legal_pages) do
      add :lock_version, :integer, null: false, default: 1
    end
  end
end
