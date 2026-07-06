defmodule Kammer.Repo.Migrations.AddVersionRetention do
  use Ecto.Migration

  def change do
    # Issue #15: unlimited versions by default; admins may cap history
    # per file space. NULL = unlimited.
    alter table(:groups) do
      add :version_retention, :integer
    end

    alter table(:communities) do
      add :version_retention, :integer
    end
  end
end
