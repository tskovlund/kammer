defmodule Kammer.Groups.GroupMembership do
  @moduledoc """
  A user's membership of a group with a role (SPEC §3:
  Owner / Admin / Member).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}
  @type role() :: :owner | :admin | :member

  @roles [:owner, :admin, :member]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "group_memberships" do
    field :role, Ecto.Enum, values: @roles, default: :member

    belongs_to :group, Kammer.Groups.Group
    belongs_to :user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a membership.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :group_id, :user_id])
    |> validate_required([:role, :group_id, :user_id])
    |> unique_constraint([:group_id, :user_id])
  end

  @doc "All valid group roles."
  @spec roles() :: [role()]
  def roles, do: @roles
end
