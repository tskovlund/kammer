defmodule Kammer.Moderation.CommunityBan do
  @moduledoc """
  A community ban (SPEC §11): keyed on the EMAIL, not the account —
  bans survive account deletion and block rejoin through any invite.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "community_bans" do
    field :email, :string
    field :reason, :string

    belongs_to :community, Kammer.Communities.Community
    belongs_to :banned_by_user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for recording a ban. IDs set programmatically.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(ban, attrs) do
    ban
    |> cast(attrs, [:email, :reason])
    |> validate_required([:email])
    |> update_change(:email, &String.downcase/1)
    # Defense-in-depth against the #334 control-char→DB-500 class: today
    # the email is sourced from an already-validated `User.email`, but the
    # rule belongs on the changeset so a future raw-email caller is safe.
    |> Kammer.Validation.validate_email_format(:email,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:reason, max: 2_000)
    # error_key so the 422 detail lands on `email`, the human-meaningful
    # half of the composite — Ecto's default is the FIRST field
    # (`community_id`), which no client form can map to an input.
    |> unique_constraint([:community_id, :email], error_key: :email)
  end
end
