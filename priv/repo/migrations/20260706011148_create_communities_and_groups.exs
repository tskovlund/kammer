defmodule Kammer.Repo.Migrations.CreateCommunitiesAndGroups do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :instance_operator, :boolean, null: false, default: false
    end

    create table(:instance_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :singleton_guard, :integer, null: false, default: 1
      add :instance_name, :string
      add :default_locale, :string, null: false, default: "en"
      add :community_creation_policy, :string, null: false, default: "operators_only"
      add :setup_completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:instance_settings, [:singleton_guard])

    create table(:communities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :citext, null: false
      add :description, :text
      add :accent_color, :string, null: false, default: "#3E6B48"
      add :default_locale, :string, null: false, default: "en"
      add :listed_on_instance, :boolean, null: false, default: false
      add :require_real_names, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:communities, [:slug])

    create table(:community_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:community_memberships, [:community_id, :user_id])
    create index(:community_memberships, [:user_id])

    create table(:groups, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :slug, :citext, null: false
      add :description, :text
      add :visibility, :string, null: false, default: "community"
      add :join_policy, :string, null: false, default: "open"
      add :posting_policy, :string, null: false, default: "all_members"
      add :comment_policy, :string, null: false, default: "members"
      add :approval_queue, :boolean, null: false, default: false
      add :sealed, :boolean, null: false, default: false
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:groups, [:community_id, :slug])
    create index(:groups, [:community_id])

    create table(:group_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_memberships, [:group_id, :user_id])
    create index(:group_memberships, [:user_id])

    create table(:group_join_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :message, :text
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_join_requests, [:group_id, :user_id],
             where: "status = 'pending'",
             name: :group_join_requests_pending_unique_index
           )

    create table(:invites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token, :string, null: false

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all)

      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :invited_email, :citext
      add :expires_at, :utc_datetime
      add :max_uses, :integer
      add :use_count, :integer, null: false, default: 0
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invites, [:token])
    create index(:invites, [:community_id])
    create index(:invites, [:group_id])

    create table(:instance_bookmarks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :url, :string, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:instance_bookmarks, [:user_id])
  end
end
