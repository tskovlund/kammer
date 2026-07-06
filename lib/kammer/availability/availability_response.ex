defmodule Kammer.Availability.AvailabilityResponse do
  @moduledoc """
  One member's answer to one candidate date: yes, if needed, or no.
  One answer per person per date, replaced on change.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}
  @type answer() :: :yes | :if_needed | :no

  @answers [:yes, :if_needed, :no]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "availability_responses" do
    field :answer, Ecto.Enum, values: @answers

    belongs_to :option, Kammer.Availability.AvailabilityOption
    belongs_to :user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for setting an answer."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(response, attrs) do
    response
    |> cast(attrs, [:answer, :option_id, :user_id])
    |> validate_required([:answer, :option_id, :user_id])
    |> unique_constraint([:option_id, :user_id])
  end

  @doc "All valid answers."
  @spec answers() :: [answer()]
  def answers, do: @answers
end
