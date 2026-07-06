defmodule Kammer.Feed.Reaction do
  @moduledoc """
  An emoji reaction on a post or a comment (SPEC §5) — exactly one
  subject, enforced by a database check constraint.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @allowed_emoji ~w(👍 ❤️ 🎉 😂 😮 😢 🙏 🔥 🎺 🍰)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "reactions" do
    field :emoji, :string

    belongs_to :post, Kammer.Feed.Post
    belongs_to :comment, Kammer.Feed.Comment
    belongs_to :user, Kammer.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Changeset for a reaction. The emoji must come from the curated set —
  a small, calm palette rather than the full emoji keyboard.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:emoji, :post_id, :comment_id, :user_id])
    |> validate_required([:emoji, :user_id])
    |> validate_inclusion(:emoji, @allowed_emoji)
    |> check_constraint(:post_id, name: :reaction_subject_exactly_one)
    |> unique_constraint([:post_id, :user_id, :emoji], name: :reactions_post_user_emoji_index)
    |> unique_constraint([:comment_id, :user_id, :emoji],
      name: :reactions_comment_user_emoji_index
    )
  end

  @doc "The curated set of reaction emoji."
  @spec allowed_emoji() :: [String.t()]
  def allowed_emoji, do: @allowed_emoji
end
