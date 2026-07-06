defmodule Kammer.Availability.AvailabilityOption do
  @moduledoc """
  One candidate date in an availability poll.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "availability_options" do
    field :starts_at, :utc_datetime
    field :position, :integer, default: 0

    belongs_to :poll, Kammer.Availability.AvailabilityPoll
    has_many :responses, Kammer.Availability.AvailabilityResponse, foreign_key: :option_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a candidate date."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(option, attrs) do
    option
    |> cast(attrs, [:starts_at, :position])
    |> validate_required([:starts_at])
  end
end
