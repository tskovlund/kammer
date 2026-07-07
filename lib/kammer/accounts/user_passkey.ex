defmodule Kammer.Accounts.UserPasskey do
  @moduledoc """
  A registered WebAuthn credential (SPEC §16, ADR 0018): the passkey
  itself. `credential_id` is the lookup key for usernameless sign-in —
  we don't know which user is signing in until we've found the
  credential they used — so it is unique instance-wide. `public_key_cose`
  is the raw COSE key map Wax returned at registration, opaque to
  everything except `Wax.CoseKey.verify/3`.
  """

  use Ecto.Schema

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_passkeys" do
    field :credential_id, :binary
    field :public_key_cose, :binary
    field :aaguid, :binary
    field :sign_count, :integer, default: 0
    field :nickname, :string
    field :last_used_at, :utc_datetime

    belongs_to :user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
