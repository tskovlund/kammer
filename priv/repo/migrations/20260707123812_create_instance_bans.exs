defmodule Kammer.Repo.Migrations.CreateInstanceBans do
  use Ecto.Migration

  def change do
    create table(:instance_bans, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Instance-wide bans block every community's
      # `Communities.add_member/3`, not just one — no community_id,
      # unlike `community_bans`. Keyed on EMAIL for the same reason
      # (survives account deletion, blocks rejoin through any invite).
      add :email, :string, null: false
      add :reason, :text
      add :banned_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:instance_bans, [:email])
  end
end
