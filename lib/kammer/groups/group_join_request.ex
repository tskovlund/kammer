defmodule Kammer.Groups.GroupJoinRequest do
  @moduledoc """
  A pending request to join a group with `request_approval` join policy
  (SPEC §3). Approving creates a membership; denying just closes the
  request.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @statuses [:pending, :approved, :denied]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "group_join_requests" do
    field :message, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending

    belongs_to :group, Kammer.Groups.Group
    belongs_to :user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a join request.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(join_request, attrs) do
    join_request
    |> cast(attrs, [:message, :group_id, :user_id])
    |> validate_required([:group_id, :user_id])
    |> validate_length(:message, max: 500)
    |> unique_constraint([:group_id, :user_id],
      name: :group_join_requests_pending_unique_index,
      message: "already has a pending request"
    )
  end
end
