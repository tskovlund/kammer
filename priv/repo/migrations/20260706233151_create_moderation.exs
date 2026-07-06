defmodule Kammer.Repo.Migrations.CreateModeration do
  use Ecto.Migration

  def change do
    create table(:reports, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      add :reporter_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      # Exactly one subject; the report dies with its content.
      add :post_id, references(:posts, type: :binary_id, on_delete: :delete_all)
      add :comment_id, references(:comments, type: :binary_id, on_delete: :delete_all)

      add :reason, :text, null: false
      add :status, :string, null: false, default: "open"
      add :resolved_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create constraint(:reports, :report_subject_exactly_one,
             check: "num_nonnulls(post_id, comment_id) = 1"
           )

    create index(:reports, [:community_id, :status])

    # One open report per person per subject: enough signal, no spam.
    create unique_index(:reports, [:reporter_user_id, :post_id],
             where: "status = 'open' AND post_id IS NOT NULL",
             name: :reports_one_open_per_post
           )

    create unique_index(:reports, [:reporter_user_id, :comment_id],
             where: "status = 'open' AND comment_id IS NOT NULL",
             name: :reports_one_open_per_comment
           )

    create table(:community_bans, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :community_id, references(:communities, type: :binary_id, on_delete: :delete_all),
        null: false

      # Bans block rejoin by EMAIL (SPEC §11) — the person, not the
      # account, which may be deleted and recreated.
      add :email, :string, null: false
      add :reason, :text
      add :banned_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:community_bans, [:community_id, :email])
  end
end
