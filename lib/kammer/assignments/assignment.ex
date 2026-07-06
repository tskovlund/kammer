defmodule Kammer.Assignments.Assignment do
  @moduledoc """
  A lightweight task in a group (issue #17, owner-designed): a flat
  list, not a board. Three states, all derived: open (no claims),
  claimed (someone said "I'll take it"), done (`completed_at`).
  Claiming is first-class — associations run on volunteering, not on
  being assigned. Feature-gated per group (`:assignments`, OFF by
  default).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "assignments" do
    field :title, :string
    field :notes_markdown, :string
    field :due_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :community, Kammer.Communities.Community
    belongs_to :group, Kammer.Groups.Group
    belongs_to :created_by_user, Kammer.Accounts.User
    belongs_to :completed_by_user, Kammer.Accounts.User

    has_many :claims, Kammer.Assignments.AssignmentClaim
    has_many :comments, Kammer.Feed.Comment

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating and editing. IDs are set programmatically by
  the context, never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:title, :notes_markdown, :due_at])
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:notes_markdown, max: 10_000)
  end

  @doc "Whether the assignment is done."
  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{completed_at: completed_at}), do: not is_nil(completed_at)
end
