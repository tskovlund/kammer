defmodule Kammer.Events.EventRsvp do
  @moduledoc """
  An RSVP to an event: yes / no / maybe (SPEC §6), held by exactly one
  identity — a member (`user_id`) or an email-verified guest
  (`guest_identity_id`); a database check enforces the exactly-one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}
  @type status() :: :yes | :no | :maybe

  @statuses [:yes, :no, :maybe]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "event_rsvps" do
    field :status, Ecto.Enum, values: @statuses

    belongs_to :event, Kammer.Events.Event
    belongs_to :user, Kammer.Accounts.User
    belongs_to :guest_identity, Kammer.Guests.GuestIdentity

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or changing a member's RSVP.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rsvp, attrs) do
    rsvp
    |> cast(attrs, [:status, :event_id, :user_id])
    |> validate_required([:status, :event_id, :user_id])
    |> check_constraint(:user_id, name: :rsvp_identity_exactly_one)
    |> unique_constraint([:event_id, :user_id])
  end

  @doc """
  Changeset for creating or changing a guest's RSVP.
  """
  @spec guest_changeset(t(), map()) :: Ecto.Changeset.t()
  def guest_changeset(rsvp, attrs) do
    rsvp
    |> cast(attrs, [:status, :event_id, :guest_identity_id])
    |> validate_required([:status, :event_id, :guest_identity_id])
    |> check_constraint(:guest_identity_id, name: :rsvp_identity_exactly_one)
    |> unique_constraint([:event_id, :guest_identity_id])
  end

  @doc "All valid RSVP statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses
end
