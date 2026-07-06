defmodule Kammer.Repo.Migrations.AddGuestIdentities do
  use Ecto.Migration

  def change do
    # Email-only identities (SPEC §2): guests exist only through their
    # email; registering with the same email later claims this history.
    create table(:guest_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :display_name, :string, null: false
      add :verified_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:guest_identities, [:email])

    alter table(:event_rsvps) do
      modify :user_id, :binary_id, null: true, from: {:binary_id, null: false}

      add :guest_identity_id,
          references(:guest_identities, type: :binary_id, on_delete: :delete_all)
    end

    create unique_index(:event_rsvps, [:event_id, :guest_identity_id],
             where: "guest_identity_id IS NOT NULL"
           )

    # An RSVP belongs to exactly one kind of identity.
    create constraint(:event_rsvps, :rsvp_identity_exactly_one,
             check: "num_nonnulls(user_id, guest_identity_id) = 1"
           )
  end
end
