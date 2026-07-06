defmodule Kammer.Repo.Migrations.CreateEventSlots do
  use Ecto.Migration

  def change do
    create table(:event_slots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :capacity, :integer, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:event_slots, [:event_id])
    create constraint(:event_slots, :slot_capacity_positive, check: "capacity >= 1")

    create table(:slot_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :slot_id, references(:event_slots, type: :binary_id, on_delete: :delete_all),
        null: false

      # A claim is a personal commitment: it disappears with its person
      # (delete_all both ways), so exactly-one holds — unlike comments,
      # nothing here survives its author.
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)

      add :guest_identity_id,
          references(:guest_identities, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create constraint(:slot_claims, :claim_identity_exactly_one,
             check: "num_nonnulls(user_id, guest_identity_id) = 1"
           )

    create unique_index(:slot_claims, [:slot_id, :user_id],
             where: "user_id IS NOT NULL",
             name: :slot_claims_one_per_user
           )

    create unique_index(:slot_claims, [:slot_id, :guest_identity_id],
             where: "guest_identity_id IS NOT NULL",
             name: :slot_claims_one_per_guest
           )

    create index(:slot_claims, [:guest_identity_id])
  end
end
