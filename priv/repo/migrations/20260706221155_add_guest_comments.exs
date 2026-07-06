defmodule Kammer.Repo.Migrations.AddGuestComments do
  use Ecto.Migration

  def change do
    alter table(:comments) do
      add :guest_identity_id,
          references(:guest_identities, type: :binary_id, on_delete: :delete_all)

      add :pending_approval, :boolean, default: false, null: false
    end

    # At most one author: a comment is authored by a member OR a guest.
    # Not exactly-one — deleting a user account nilifies author_user_id
    # (the comment stays as "Deleted user"), which must remain legal.
    create constraint(:comments, :comment_author_at_most_one,
             check: "num_nonnulls(author_user_id, guest_identity_id) <= 1"
           )

    create index(:comments, [:guest_identity_id])
    create index(:comments, [:post_id], where: "pending_approval", name: :comments_pending_index)
  end
end
