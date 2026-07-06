defmodule Kammer.Repo.Migrations.AddGroupFeatures do
  use Ecto.Migration

  def change do
    # Per-group feature toggles (ADR 0016). Every current feature is on
    # for existing and new groups; future features ship OFF by default.
    alter table(:groups) do
      add :features, {:array, :string}, null: false, default: ["feed", "events", "files"]
    end
  end
end
