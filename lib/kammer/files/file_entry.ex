defmodule Kammer.Files.FileEntry do
  @moduledoc """
  The logical file (issue #15): name, place, and permissions target,
  pointing at its current version. Every version is a `StoredFile` row
  carrying the same scope columns as the entry, so blob-level access
  checks and storage accounting need no special cases — the entry adds
  identity and history on top.

  Feed attachments and transient uploads are deliberately entry-less:
  they are artifacts of posts, not documents.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "file_entries" do
    field :name, :string

    belongs_to :community, Kammer.Communities.Community
    belongs_to :group, Kammer.Groups.Group
    belongs_to :folder, Kammer.Files.Folder
    belongs_to :current_version, Kammer.Files.StoredFile

    has_many :versions, Kammer.Files.StoredFile, foreign_key: :file_entry_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating an entry.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:name, :community_id, :group_id, :folder_id])
    |> validate_required([:name, :community_id])
    |> validate_length(:name, max: 255)
  end
end
