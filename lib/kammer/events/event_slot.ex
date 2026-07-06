defmodule Kammer.Events.EventSlot do
  @moduledoc """
  A volunteer signup slot on an event (issue #37, collaborative track
  #17): "bring cake ×2, drive ×4". Capacity-bounded; members and
  email-verified guests claim it. Slots belong to event managers; the
  claims belong to the people who gave them.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "event_slots" do
    field :title, :string
    field :capacity, :integer
    field :position, :integer, default: 0

    belongs_to :event, Kammer.Events.Event
    has_many :claims, Kammer.Events.SlotClaim, foreign_key: :slot_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or editing a slot. `event_id` is set
  programmatically by the context, never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(slot, attrs) do
    slot
    |> cast(attrs, [:title, :capacity, :position])
    |> validate_required([:title, :capacity])
    |> validate_length(:title, min: 1, max: 200)
    |> validate_number(:capacity, greater_than_or_equal_to: 1, less_than_or_equal_to: 1_000)
    |> check_constraint(:capacity, name: :slot_capacity_positive)
  end
end
