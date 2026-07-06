defmodule Kammer.Decisions.Decision do
  @moduledoc """
  A register entry (issue #43, collaborative track #17): one motion,
  carried by a feed post (the text and, usually, a For/Against/Abstain
  poll as the vote), with the recorded outcome. The register is the
  group's minutes-grade institutional memory. Feature-gated per group
  (`:decisions`, OFF by default).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}
  @type outcome() :: :adopted | :rejected | :noted

  @outcomes [:adopted, :rejected, :noted]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "decisions" do
    field :title, :string
    field :outcome, Ecto.Enum, values: @outcomes
    field :outcome_note, :string
    field :decided_at, :utc_datetime

    belongs_to :community, Kammer.Communities.Community
    belongs_to :group, Kammer.Groups.Group
    belongs_to :post, Kammer.Feed.Post
    belongs_to :decided_by_user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a decision. IDs are set programmatically by
  the context, never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [:title])
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 200)
  end

  @doc "Changeset for recording (or amending) the outcome."
  @spec outcome_changeset(t(), map()) :: Ecto.Changeset.t()
  def outcome_changeset(decision, attrs) do
    decision
    |> cast(attrs, [:outcome, :outcome_note])
    |> validate_required([:outcome])
    |> validate_length(:outcome_note, max: 2_000)
  end

  @doc "All valid outcomes."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc "Whether an outcome has been recorded."
  @spec decided?(t()) :: boolean()
  def decided?(%__MODULE__{outcome: outcome}), do: not is_nil(outcome)
end
