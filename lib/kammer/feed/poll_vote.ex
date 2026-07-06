defmodule Kammer.Feed.PollVote do
  @moduledoc """
  A member's vote for a poll option.
  """

  use Ecto.Schema

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "poll_votes" do
    belongs_to :poll, Kammer.Feed.Poll
    belongs_to :option, Kammer.Feed.PollOption
    belongs_to :user, Kammer.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
