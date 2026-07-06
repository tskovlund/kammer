defmodule Kammer.Repo.Migrations.AddShowInHomeToMemberships do
  use Ecto.Migration

  def change do
    # ADR 0015: each member controls whether a group's activity appears
    # in their merged Home. Defaults ON — including for sealed groups
    # (owner decision, option 1) — with a prominent toggle in the UI.
    alter table(:group_memberships) do
      add :show_in_home, :boolean, null: false, default: true
    end
  end
end
