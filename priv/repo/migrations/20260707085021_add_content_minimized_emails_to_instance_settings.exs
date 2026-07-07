defmodule Kammer.Repo.Migrations.AddContentMinimizedEmailsToInstanceSettings do
  use Ecto.Migration

  def change do
    alter table(:instance_settings) do
      add :content_minimized_emails, :boolean, default: false, null: false
    end
  end
end
