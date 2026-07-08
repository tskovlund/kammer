defmodule Kammer.Events.EventSeries do
  @moduledoc """
  A recurring event series (SPEC §6): "constrained RRULE" — weekly,
  biweekly, or monthly, bounded by an end date; no freeform editor. The
  series row only records the recurrence rule. Every occurrence is a
  materialized `Event` row (`series_id`), so RSVPs, slots, comments,
  ICS feeds, and reminders all keep working completely unchanged.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}
  @type frequency() :: :weekly | :biweekly | :monthly

  @frequencies [:weekly, :biweekly, :monthly]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "event_series" do
    field :frequency, Ecto.Enum, values: @frequencies
    field :until, :date

    belongs_to :community, Kammer.Communities.Community
    belongs_to :group, Kammer.Groups.Group
    belongs_to :created_by_user, Kammer.Accounts.User

    has_many :events, Kammer.Events.Event, foreign_key: :series_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a new series. Whether `until` is late enough to
  produce at least one occurrence depends on the base event's start
  date, which this changeset doesn't have — the context checks that.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(series, attrs) do
    series
    |> cast(attrs, [:frequency, :until, :community_id, :group_id, :created_by_user_id])
    |> validate_required([:frequency, :until, :community_id, :group_id, :created_by_user_id])
  end
end
