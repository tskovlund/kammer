defmodule Kammer.Communities.CommunityMembership do
  @moduledoc """
  A user's membership of a community with a role (SPEC §3:
  Owner / Admin / Member).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}
  @type role() :: :owner | :admin | :member

  @roles [:owner, :admin, :member]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "community_memberships" do
    field :role, Ecto.Enum, values: @roles, default: :member

    belongs_to :community, Kammer.Communities.Community
    belongs_to :user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a membership.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :community_id, :user_id])
    |> validate_required([:role, :community_id, :user_id])
    |> unique_constraint([:community_id, :user_id])
  end

  @doc "All valid community roles."
  @spec roles() :: [role()]
  def roles, do: @roles
end
