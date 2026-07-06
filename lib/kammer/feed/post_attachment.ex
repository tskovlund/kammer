defmodule Kammer.Feed.PostAttachment do
  @moduledoc """
  Join between a post and a stored file (SPEC §5): deleting a post never
  deletes the file — only this link.
  """

  use Ecto.Schema

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "post_attachments" do
    field :position, :integer, default: 0

    belongs_to :post, Kammer.Feed.Post
    belongs_to :stored_file, Kammer.Files.StoredFile
  end
end
