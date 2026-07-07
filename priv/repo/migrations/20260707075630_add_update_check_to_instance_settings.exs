defmodule Kammer.Repo.Migrations.AddUpdateCheckToInstanceSettings do
  use Ecto.Migration

  def change do
    alter table(:instance_settings) do
      add :latest_known_version, :string
      add :latest_known_release_url, :string
      add :update_checked_at, :utc_datetime
    end
  end
end
