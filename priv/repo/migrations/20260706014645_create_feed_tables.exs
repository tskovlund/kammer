defmodule Kammer.Repo.Migrations.CreateFeedTables do
  use Ecto.Migration

  def change do
    create table(:stored_files, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all)
      add :uploader_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :bigint, null: false
      add :storage_key, :string, null: false
      add :kind, :string, null: false, default: "file"
      add :width, :integer
      add :height, :integer
      add :thumbnail_key, :string
      add :processed_at, :utc_datetime
      add :transient_expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:stored_files, [:storage_key])
    create index(:stored_files, [:community_id])
    create index(:stored_files, [:group_id])
    create index(:stored_files, [:transient_expires_at])

    create table(:posts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :author_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :author_type, :string, null: false, default: "user"
      add :body_markdown, :text, null: false
      add :published_at, :utc_datetime, null: false
      add :pending_approval, :boolean, null: false, default: false
      add :acknowledgment_required, :boolean, null: false, default: false
      add :pinned_at, :utc_datetime
      add :comment_locked_at, :utc_datetime
      add :edited_at, :utc_datetime
      add :deleted_at, :utc_datetime
      add :deleted_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :purged_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:posts, [:group_id, :published_at])
    create index(:posts, [:community_id, :published_at])
    create index(:posts, [:deleted_at])

    create table(:post_edits, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :post_id, references(:posts, type: :binary_id, on_delete: :delete_all), null: false
      add :editor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :previous_body_markdown, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:post_edits, [:post_id])

    create table(:post_acknowledgments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :post_id, references(:posts, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:post_acknowledgments, [:post_id, :user_id])

    create table(:post_attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :post_id, references(:posts, type: :binary_id, on_delete: :delete_all), null: false

      add :stored_file_id, references(:stored_files, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false, default: 0
    end

    create unique_index(:post_attachments, [:post_id, :stored_file_id])

    create table(:comments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :post_id, references(:posts, type: :binary_id, on_delete: :delete_all), null: false
      add :parent_comment_id, references(:comments, type: :binary_id, on_delete: :delete_all)
      add :author_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :body_markdown, :text, null: false
      add :edited_at, :utc_datetime
      add :deleted_at, :utc_datetime
      add :purged_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:comments, [:post_id, :inserted_at])
    create index(:comments, [:parent_comment_id])

    create table(:reactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :post_id, references(:posts, type: :binary_id, on_delete: :delete_all)
      add :comment_id, references(:comments, type: :binary_id, on_delete: :delete_all)
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :emoji, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:reactions, :reaction_subject_exactly_one,
             check:
               "(post_id IS NOT NULL AND comment_id IS NULL) OR (post_id IS NULL AND comment_id IS NOT NULL)"
           )

    create unique_index(:reactions, [:post_id, :user_id, :emoji],
             where: "post_id IS NOT NULL",
             name: :reactions_post_user_emoji_index
           )

    create unique_index(:reactions, [:comment_id, :user_id, :emoji],
             where: "comment_id IS NOT NULL",
             name: :reactions_comment_user_emoji_index
           )

    create table(:polls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :post_id, references(:posts, type: :binary_id, on_delete: :delete_all), null: false
      add :multiple_choice, :boolean, null: false, default: false
      add :anonymous, :boolean, null: false, default: false
      add :closes_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polls, [:post_id])

    create table(:poll_options, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :poll_id, references(:polls, type: :binary_id, on_delete: :delete_all), null: false
      add :text, :string, null: false
      add :position, :integer, null: false, default: 0
    end

    create index(:poll_options, [:poll_id])

    create table(:poll_votes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :poll_id, references(:polls, type: :binary_id, on_delete: :delete_all), null: false

      add :option_id, references(:poll_options, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:poll_votes, [:option_id, :user_id])
    create index(:poll_votes, [:poll_id, :user_id])

    create table(:feed_visits, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :last_visited_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:feed_visits, [:user_id, :group_id])
  end
end
