defmodule Kammer.Events.EventRsvp do
  @moduledoc """
  A member's RSVP to an event: yes / no / maybe (SPEC §6).
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

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or changing an RSVP.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rsvp, attrs) do
    rsvp
    |> cast(attrs, [:status, :event_id, :user_id])
    |> validate_required([:status, :event_id, :user_id])
    |> unique_constraint([:event_id, :user_id])
  end

  @doc "All valid RSVP statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses
end
