defmodule Kammer.Repo.Migrations.MakeAuditEventsCommunityNullable do
  use Ecto.Migration

  def change do
    # An instance-operator action with no community to attribute it to — a
    # no-account instance ban, or any instance unban (#276) — carries a null
    # community_id. Those rows are the instance-level audit log; every
    # existing row is community-scoped and unaffected.
    alter table(:audit_events) do
      modify :community_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    # Serves the instance-audit cursor page — `community_id IS NULL`, newest
    # first with an id tiebreaker — without competing with the community
    # index on the vastly larger community-scoped slice.
    create index(:audit_events, [:inserted_at, :id],
             where: "community_id IS NULL",
             name: :audit_events_instance_idx
           )
  end
end
