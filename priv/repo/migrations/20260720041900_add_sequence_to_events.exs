defmodule Kammer.Repo.Migrations.AddSequenceToEvents do
  use Ecto.Migration

  # iTIP revision counter for the ICS export (#363): RFC 5545 §3.8.7.4's
  # SEQUENCE, bumped on each significant revision (an edit to an exported
  # field, a cancel, an uncancel) so a subscribed calendar reliably re-processes
  # the change instead of silently ignoring it. `default: 0` backfills existing
  # rows to the RFC's initial value and backs up column-omitting inserts; the
  # counter only ever increases from there via `Kammer.Events`.
  def change do
    alter table(:events) do
      add :sequence, :integer, null: false, default: 0
    end
  end
end
