defmodule Kammer.Events.EventRsvp do
  @moduledoc """
  An RSVP to an event: yes / no / maybe (SPEC §6), held by exactly one
  identity — a member (`user_id`) or an email-verified guest
  (`guest_identity_id`); a database check enforces the exactly-one.

  `:waitlisted` (issue #318) is a derived status, never requested: a
  "yes" beyond the event's capacity lands here, ordered by
  `waitlisted_at` (id as tiebreaker) — a stable, gap-tolerant queue
  `Kammer.Events` promotes from when a seat frees up. Callers only ever
  ask for yes/no/maybe; the context decides when yes means waitlisted.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}
  @type status() :: :yes | :no | :maybe | :waitlisted

  @statuses [:yes, :no, :maybe, :waitlisted]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "event_rsvps" do
    field :status, Ecto.Enum, values: @statuses
    field :waitlisted_at, :utc_datetime_usec

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

  @doc """
  The statuses a caller may request (SPEC §6) — `:waitlisted` is derived
  by the context from the event's capacity, never asked for directly.
  """
  @spec requestable_statuses() :: [status()]
  def requestable_statuses, do: [:yes, :no, :maybe]
end
