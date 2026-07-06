defmodule Kammer.Assignments.AssignmentClaim do
  @moduledoc """
  One person's "I'll take it" on an assignment. Multiple people may
  claim the same assignment (#17: simultaneous assignees); one claim
  per person.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "assignment_claims" do
    belongs_to :assignment, Kammer.Assignments.Assignment
    belongs_to :user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for claiming."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [:assignment_id, :user_id])
    |> validate_required([:assignment_id, :user_id])
    |> unique_constraint([:assignment_id, :user_id])
  end
end
