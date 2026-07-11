defmodule Kammer.Moderation.InstanceBan do
  @moduledoc """
  An instance-wide ban (SPEC §11): keyed on the EMAIL like
  `CommunityBan`, but blocks every community's
  `Communities.add_member/3` on this instance, not just one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "instance_bans" do
    field :email, :string
    field :reason, :string

    belongs_to :banned_by_user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for recording an instance ban. IDs set programmatically.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(ban, attrs) do
    ban
    |> cast(attrs, [:email, :reason])
    |> validate_required([:email])
    |> update_change(:email, &String.downcase/1)
    # The column is varchar(255); without the cap an oversized string is
    # a raw DB error (500), not a changeset 422.
    |> validate_length(:email, max: 255)
    |> validate_length(:reason, max: 2_000)
    |> unique_constraint(:email)
  end
end
