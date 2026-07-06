defmodule Kammer.Feed.FeedVisit do
  @moduledoc """
  Per-user last-visit timestamp for a group feed, powering the
  new-since-last-visit marker (SPEC §5). Not "seen by" tracking — it is
  private to the user and never shown to others.
  """

  use Ecto.Schema

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "feed_visits" do
    field :last_visited_at, :utc_datetime

    belongs_to :user, Kammer.Accounts.User
    belongs_to :group, Kammer.Groups.Group

    timestamps(type: :utc_datetime)
  end
end
