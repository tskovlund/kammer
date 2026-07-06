defmodule Kammer.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all)
      add :actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :post_id, references(:posts, type: :binary_id, on_delete: :delete_all)
      add :comment_id, references(:comments, type: :binary_id, on_delete: :delete_all)
      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all)
      add :read_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:notifications, [:user_id, :read_at])
    create index(:notifications, [:user_id, :inserted_at])

    create table(:notification_preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :level, :string, null: false, default: "highlights"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:notification_preferences, [:user_id, :group_id])

    create table(:push_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :endpoint, :text, null: false
      add :p256dh_key, :string, null: false
      add :auth_key, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscriptions, [:user_id, :endpoint])
  end
end
