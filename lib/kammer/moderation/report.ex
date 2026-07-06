defmodule Kammer.Moderation.Report do
  @moduledoc """
  A member's report of a post or comment (SPEC §11) — exactly one
  subject, one open report per person per subject (signal, not spam),
  and a recorded resolution. The report dies with its content.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}
  @type status() :: :open | :dismissed | :resolved

  @statuses [:open, :dismissed, :resolved]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "reports" do
    field :reason, :string
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :resolved_at, :utc_datetime

    belongs_to :community, Kammer.Communities.Community
    belongs_to :reporter_user, Kammer.Accounts.User
    belongs_to :post, Kammer.Feed.Post
    belongs_to :comment, Kammer.Feed.Comment
    belongs_to :resolved_by_user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for filing a report. IDs are set programmatically by the
  context, never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(report, attrs) do
    report
    |> cast(attrs, [:reason])
    |> validate_required([:reason])
    |> validate_length(:reason, min: 1, max: 2_000)
    |> check_constraint(:post_id, name: :report_subject_exactly_one)
    |> unique_constraint([:reporter_user_id, :post_id], name: :reports_one_open_per_post)
    |> unique_constraint([:reporter_user_id, :comment_id], name: :reports_one_open_per_comment)
  end
end
