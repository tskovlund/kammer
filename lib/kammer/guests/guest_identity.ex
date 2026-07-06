defmodule Kammer.Guests.GuestIdentity do
  @moduledoc """
  An email-only identity (SPEC §2): guests RSVP to public events (and
  later comment, subscribe) without an account. The email is the whole
  identity — registering with it later claims this history and the
  guest record disappears.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "guest_identities" do
    field :email, :string
    field :display_name, :string
    field :verified_at, :utc_datetime

    has_many :event_rsvps, Kammer.Events.EventRsvp

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or refreshing a guest identity.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:email, :display_name])
    |> validate_required([:email, :display_name])
    |> update_change(:email, &String.downcase/1)
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> validate_length(:display_name, min: 1, max: 120)
    |> unique_constraint(:email)
  end
end
