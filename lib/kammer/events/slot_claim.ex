defmodule Kammer.Events.SlotClaim do
  @moduledoc """
  One person's claim on a signup slot — a member (`user_id`) or an
  email-verified guest (`guest_identity_id`), exactly one (a claim is a
  personal commitment; it disappears with its person). One claim per
  person per slot.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "slot_claims" do
    belongs_to :slot, Kammer.Events.EventSlot
    belongs_to :user, Kammer.Accounts.User
    belongs_to :guest_identity, Kammer.Guests.GuestIdentity

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a member's claim."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [:slot_id, :user_id])
    |> validate_required([:slot_id, :user_id])
    |> check_constraint(:user_id, name: :claim_identity_exactly_one)
    |> unique_constraint([:slot_id, :user_id], name: :slot_claims_one_per_user)
  end

  @doc "Changeset for a guest's claim."
  @spec guest_changeset(t(), map()) :: Ecto.Changeset.t()
  def guest_changeset(claim, attrs) do
    claim
    |> cast(attrs, [:slot_id, :guest_identity_id])
    |> validate_required([:slot_id, :guest_identity_id])
    |> check_constraint(:guest_identity_id, name: :claim_identity_exactly_one)
    |> unique_constraint([:slot_id, :guest_identity_id], name: :slot_claims_one_per_guest)
  end
end
