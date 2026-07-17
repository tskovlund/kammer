defmodule Kammer.Invitations.Invite do
  @moduledoc """
  An invite link (SPEC §3): community-wide or into a specific group, with
  optional expiry and max-use count, revocable. Email invites carry the
  invited address.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Kammer.Validation

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "invites" do
    field :token, :string
    field :invited_email, :string
    field :expires_at, :utc_datetime
    field :max_uses, :integer
    field :use_count, :integer, default: 0
    field :revoked_at, :utc_datetime

    belongs_to :community, Kammer.Communities.Community
    belongs_to :group, Kammer.Groups.Group
    belongs_to :created_by_user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating an invite. The token is generated, never cast.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(invite, attrs) do
    invite
    |> cast(attrs, [
      :invited_email,
      :expires_at,
      :max_uses,
      :community_id,
      :group_id,
      :created_by_user_id
    ])
    |> validate_required([:community_id])
    # Optional by design — a link invite carries no address (issue
    # #305). When present it must be deliverable: same shared format
    # rule as every other email field, downcased like the guest and
    # newsletter email writes (the column is citext, so this is display
    # normalization — comparisons were already case-insensitive).
    |> update_change(:invited_email, &String.downcase/1)
    |> Validation.validate_email_format(:invited_email,
      message: "must have the @ sign and no spaces"
    )
    |> validate_number(:max_uses, greater_than: 0)
    |> put_change(:token, generate_token())
    |> unique_constraint(:token)
  end

  @doc """
  Whether the invite can still be redeemed right now.
  """
  @spec redeemable?(t(), DateTime.t()) :: boolean()
  def redeemable?(%__MODULE__{} = invite, %DateTime{} = now) do
    not revoked?(invite) and not expired?(invite, now) and not used_up?(invite)
  end

  defp revoked?(%__MODULE__{revoked_at: revoked_at}), do: not is_nil(revoked_at)

  defp expired?(%__MODULE__{expires_at: nil}, _now), do: false

  defp expired?(%__MODULE__{expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) == :gt

  defp used_up?(%__MODULE__{max_uses: nil}), do: false
  defp used_up?(%__MODULE__{max_uses: max_uses, use_count: use_count}), do: use_count >= max_uses

  defp generate_token do
    Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end
end
