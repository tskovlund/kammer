defmodule Kammer.Events.Event do
  @moduledoc """
  An event (SPEC §6): timezone-aware start (+ optional end), all-day and
  multi-day supported, Markdown description, free-text location with
  optional URL (map links derived client-side — no embedded trackers),
  hosted by a group. Uses the same comment engine as posts (ADR 0007).

  A recurring series materializes as one `Event` row per occurrence,
  linked by `series_id` (`Kammer.Events.EventSeries`); `cancelled_at`
  is the per-instance "cancel one date" override — the row (and its
  RSVPs/comments) stays, just excluded from listings, reminders, and
  ICS feeds.

  `capacity` (issue #318) caps attending RSVPs — members and confirmed
  guests count under the one cap; `nil` means unlimited. Beyond the cap
  new "yes" answers become `:waitlisted` (`Kammer.Events.EventRsvp`),
  and `Kammer.Events` promotes from the waitlist whenever seats free
  up. Lowering the capacity never demotes anyone already attending.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Kammer.Validation

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "events" do
    field :title, :string
    field :description_markdown, :string
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :all_day, :boolean, default: false
    field :timezone, :string, default: "Etc/UTC"
    field :location_name, :string
    field :location_url, :string
    field :capacity, :integer
    field :comment_locked_at, :utc_datetime
    field :cancelled_at, :utc_datetime

    belongs_to :community, Kammer.Communities.Community
    belongs_to :group, Kammer.Groups.Group
    belongs_to :created_by_user, Kammer.Accounts.User
    belongs_to :series, Kammer.Events.EventSeries

    has_many :rsvps, Kammer.Events.EventRsvp
    has_many :comments, Kammer.Feed.Comment
    has_many :slots, Kammer.Events.EventSlot

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating and updating an event.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :title,
      :description_markdown,
      :starts_at,
      :ends_at,
      :all_day,
      :timezone,
      :location_name,
      :location_url,
      :capacity,
      :community_id,
      :group_id,
      :created_by_user_id
    ])
    |> validate_required([:title, :starts_at, :community_id, :group_id])
    |> validate_number(:capacity, greater_than: 0)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:description_markdown, max: 50_000)
    |> validate_length(:location_name, max: 200)
    |> validate_length(:location_url, max: 500)
    |> Validation.validate_http_url(:location_url)
    |> validate_end_after_start()
  end

  defp validate_end_after_start(changeset) do
    starts_at = get_field(changeset, :starts_at)
    ends_at = get_field(changeset, :ends_at)

    if starts_at && ends_at && DateTime.compare(ends_at, starts_at) == :lt do
      add_error(changeset, :ends_at, "must be after the start")
    else
      changeset
    end
  end

  @doc "Whether the event lies in the past (by end, falling back to start)."
  @spec past?(t(), DateTime.t()) :: boolean()
  def past?(%__MODULE__{} = event, %DateTime{} = now) do
    reference = event.ends_at || event.starts_at
    DateTime.compare(reference, now) == :lt
  end
end
