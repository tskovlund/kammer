defmodule Kammer.Availability.AvailabilityPoll do
  @moduledoc """
  A date-finding poll (issue #39, collaborative track #17): candidate
  dates for something that isn't an event yet. Members answer per date;
  closing the poll can convert the winning date into a real event,
  recorded in `converted_event_id`. Feature-gated per group
  (`:availability`, OFF by default — ADR 0016).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "availability_polls" do
    field :title, :string
    field :closed_at, :utc_datetime

    belongs_to :community, Kammer.Communities.Community
    belongs_to :group, Kammer.Groups.Group
    belongs_to :created_by_user, Kammer.Accounts.User
    belongs_to :converted_event, Kammer.Events.Event

    has_many :options, Kammer.Availability.AvailabilityOption, foreign_key: :poll_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a poll. IDs are set programmatically by the
  context, never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(poll, attrs) do
    poll
    |> cast(attrs, [:title])
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 200)
  end

  @doc "Whether the poll is closed."
  @spec closed?(t()) :: boolean()
  def closed?(%__MODULE__{closed_at: closed_at}), do: not is_nil(closed_at)
end
