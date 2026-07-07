defmodule Kammer.Repo.Migrations.CreateNewsletterSubscriptions do
  use Ecto.Migration

  def change do
    create table(:newsletter_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false

      add :guest_identity_id,
          references(:guest_identities, type: :binary_id, on_delete: :delete_all),
          null: false

      add :cadence, :string, null: false, default: "per_post"
      add :last_sent_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:newsletter_subscriptions, [:group_id, :guest_identity_id])
  end
end
