defmodule Kammer.Feed.PollOption do
  @moduledoc """
  One selectable option of a poll.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "poll_options" do
    field :text, :string
    field :position, :integer, default: 0

    belongs_to :poll, Kammer.Feed.Poll
    has_many :votes, Kammer.Feed.PollVote, foreign_key: :option_id
  end

  @doc """
  Changeset for a poll option.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(option, attrs) do
    option
    |> cast(attrs, [:text, :position])
    |> validate_required([:text])
    |> validate_length(:text, min: 1, max: 200)
  end
end
