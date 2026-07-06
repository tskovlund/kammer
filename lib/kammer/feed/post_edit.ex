defmodule Kammer.Feed.PostEdit do
  @moduledoc """
  Edit-history entry for a post (SPEC §5): visible to the author and
  admins, never the public.
  """

  use Ecto.Schema

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "post_edits" do
    field :previous_body_markdown, :string

    belongs_to :post, Kammer.Feed.Post
    belongs_to :editor_user, Kammer.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
