defmodule Kammer.Feed.Poll do
  @moduledoc """
  A poll attached to a post (SPEC §5): single or multiple choice,
  optional close date, per-poll anonymity toggle (default visible votes)
  that locks after the first vote.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "polls" do
    field :multiple_choice, :boolean, default: false
    field :anonymous, :boolean, default: false
    field :closes_at, :utc_datetime

    belongs_to :post, Kammer.Feed.Post
    has_many :options, Kammer.Feed.PollOption, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a poll with its options.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(poll, attrs) do
    poll
    |> cast(attrs, [:multiple_choice, :anonymous, :closes_at, :post_id])
    |> cast_assoc(:options,
      with: &Kammer.Feed.PollOption.changeset/2,
      required: true
    )
    |> validate_option_count()
  end

  defp validate_option_count(changeset) do
    options = get_field(changeset, :options) || []

    if length(options) < 2 do
      add_error(changeset, :options, "needs at least two options")
    else
      changeset
    end
  end

  @doc "Whether the poll is closed for voting."
  @spec closed?(t(), DateTime.t()) :: boolean()
  def closed?(%__MODULE__{closes_at: nil}, _now), do: false

  def closed?(%__MODULE__{closes_at: closes_at}, %DateTime{} = now),
    do: DateTime.compare(now, closes_at) == :gt
end
