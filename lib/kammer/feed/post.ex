defmodule Kammer.Feed.Post do
  @moduledoc """
  A feed post (SPEC §5): Markdown canonical body, optional poll and
  attachments, pinnable, schedulable (future `published_at`),
  acknowledgment-required option, per-post comment lock, edited marker,
  and soft-deletion stubs that preserve thread coherence.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @author_types [:user, :group]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "posts" do
    field :author_type, Ecto.Enum, values: @author_types, default: :user
    field :body_markdown, :string
    field :published_at, :utc_datetime
    field :pending_approval, :boolean, default: false
    field :acknowledgment_required, :boolean, default: false
    field :pinned_at, :utc_datetime
    field :comment_locked_at, :utc_datetime
    field :edited_at, :utc_datetime
    field :deleted_at, :utc_datetime
    field :purged_at, :utc_datetime

    belongs_to :community, Kammer.Communities.Community
    belongs_to :group, Kammer.Groups.Group
    belongs_to :author_user, Kammer.Accounts.User
    belongs_to :deleted_by_user, Kammer.Accounts.User

    has_one :poll, Kammer.Feed.Poll
    has_many :comments, Kammer.Feed.Comment
    has_many :reactions, Kammer.Feed.Reaction
    has_many :acknowledgments, Kammer.Feed.PostAcknowledgment
    has_many :attachments, Kammer.Feed.PostAttachment

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a post. `published_at` in the future makes it a
  scheduled post (SPEC §5).
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(post, attrs) do
    post
    |> cast(attrs, [
      :body_markdown,
      :author_type,
      :acknowledgment_required,
      :published_at,
      :community_id,
      :group_id,
      :author_user_id,
      :pending_approval
    ])
    |> validate_required([:body_markdown, :community_id, :group_id, :author_user_id])
    |> validate_length(:body_markdown, min: 1, max: 50_000)
  end

  @doc """
  Changeset for editing the body (author only; history is recorded
  separately in `Kammer.Feed.PostEdit`).
  """
  @spec edit_changeset(t(), map()) :: Ecto.Changeset.t()
  def edit_changeset(post, attrs) do
    post
    |> cast(attrs, [:body_markdown])
    |> validate_required([:body_markdown])
    |> validate_length(:body_markdown, min: 1, max: 50_000)
    |> put_change(:edited_at, DateTime.utc_now(:second))
  end

  @doc "Whether the post is soft-deleted (renders as a stub)."
  @spec deleted?(t()) :: boolean()
  def deleted?(%__MODULE__{deleted_at: deleted_at}), do: not is_nil(deleted_at)

  @doc "Whether the post is pinned."
  @spec pinned?(t()) :: boolean()
  def pinned?(%__MODULE__{pinned_at: pinned_at}), do: not is_nil(pinned_at)

  @doc "Whether comments are locked on this post."
  @spec comments_locked?(t()) :: boolean()
  def comments_locked?(%__MODULE__{comment_locked_at: locked_at}), do: not is_nil(locked_at)

  @doc "Whether the post is scheduled for future publication."
  @spec scheduled?(t(), DateTime.t()) :: boolean()
  def scheduled?(%__MODULE__{published_at: published_at}, %DateTime{} = now) do
    DateTime.compare(published_at, now) == :gt
  end
end
