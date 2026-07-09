defmodule Kammer.Feed.Comment do
  @moduledoc """
  A comment (SPEC §5, ADR 0007): exactly one reply level — a comment
  either has no parent or its parent is a top-level comment. Enforced in
  the context, one threading model everywhere. The same engine serves
  posts and events (exactly one subject, DB-constrained).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "comments" do
    field :body_markdown, :string
    field :edited_at, :utc_datetime
    field :deleted_at, :utc_datetime
    field :purged_at, :utc_datetime
    field :pending_approval, :boolean, default: false

    belongs_to :post, Kammer.Feed.Post
    belongs_to :event, Kammer.Events.Event
    belongs_to :assignment, Kammer.Assignments.Assignment
    belongs_to :parent_comment, Kammer.Feed.Comment
    belongs_to :author_user, Kammer.Accounts.User
    belongs_to :guest_identity, Kammer.Guests.GuestIdentity

    has_many :replies, Kammer.Feed.Comment, foreign_key: :parent_comment_id
    has_many :reactions, Kammer.Feed.Reaction

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a comment.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body_markdown, :post_id, :parent_comment_id, :author_user_id])
    |> validate_required([:body_markdown, :author_user_id])
    |> validate_length(:body_markdown, min: 1, max: 10_000)
  end

  @doc """
  Changeset for a guest's comment (SPEC §3 `members_and_guests`): always
  top-level, always awaiting moderator approval. `guest_identity_id` and
  `post_id` are set programmatically by the context, never cast.
  """
  @spec guest_create_changeset(t(), map()) :: Ecto.Changeset.t()
  def guest_create_changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body_markdown])
    |> validate_required([:body_markdown])
    |> validate_length(:body_markdown, min: 1, max: 2_000)
  end

  @doc """
  Changeset for editing the body (author only; comments carry an edited
  marker but no separate edit history, unlike posts).
  """
  @spec edit_changeset(t(), map()) :: Ecto.Changeset.t()
  def edit_changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body_markdown])
    |> validate_required([:body_markdown])
    |> validate_length(:body_markdown, min: 1, max: 10_000)
    |> put_change(:edited_at, DateTime.utc_now(:second))
  end

  @doc "Whether the comment is soft-deleted (renders as a stub)."
  @spec deleted?(t()) :: boolean()
  def deleted?(%__MODULE__{deleted_at: deleted_at}), do: not is_nil(deleted_at)
end
