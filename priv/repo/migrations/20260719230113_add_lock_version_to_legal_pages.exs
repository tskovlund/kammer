defmodule Kammer.Repo.Migrations.AddLockVersionToLegalPages do
  use Ecto.Migration

  # Optimistic concurrency for operator legal-page edits (#276 item 4): a
  # published row carries a version an editor echoes back, so a stale write
  # (another operator saved first) is refused with a 409 rather than silently
  # last-write-winning. The `default: 1` backfills any existing rows and backs
  # up column-omitting inserts; new rows are written at 1 explicitly by
  # `Kammer.Legal.first_publish/3`. The unpersisted built-in template reports 0
  # (stamped in `Kammer.Legal.get_page/1`, not a DB/schema default), keeping
  # published rows strictly ahead so a concurrent first publish can't
  # match-and-clobber the template.
  def change do
    alter table(:legal_pages) do
      add :lock_version, :integer, null: false, default: 1
    end
  end
end
