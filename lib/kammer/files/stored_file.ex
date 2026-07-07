defmodule Kammer.Files.StoredFile do
  @moduledoc """
  A stored file — a first-class database entity (SPEC §7). Every file
  belongs to exactly one owning scope: a group space (`group_id` set) or
  the community space. Feed attachments live in the owning group's space;
  transient attachments (`transient_expires_at` set) have no file-space
  home and are purged on expiry (SPEC §5).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @kinds [:image, :file]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "stored_files" do
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer
    field :storage_key, :string
    field :kind, Ecto.Enum, values: @kinds, default: :file
    field :width, :integer
    field :height, :integer
    field :thumbnail_key, :string
    field :processed_at, :utc_datetime
    field :transient_expires_at, :utc_datetime
    field :version_seq, :integer, read_after_writes: true
    field :extracted_text, :string
    field :text_extracted_at, :utc_datetime

    belongs_to :community, Kammer.Communities.Community
    belongs_to :group, Kammer.Groups.Group
    belongs_to :folder, Kammer.Files.Folder
    belongs_to :file_entry, Kammer.Files.FileEntry
    belongs_to :uploader_user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for registering a stored file.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(stored_file, attrs) do
    stored_file
    |> cast(attrs, [
      :filename,
      :content_type,
      :byte_size,
      :storage_key,
      :kind,
      :width,
      :height,
      :thumbnail_key,
      :processed_at,
      :transient_expires_at,
      :community_id,
      :group_id,
      :folder_id,
      :file_entry_id,
      :uploader_user_id
    ])
    |> validate_required([:filename, :content_type, :byte_size, :storage_key, :community_id])
    |> validate_length(:filename, max: 255)
    |> unique_constraint(:storage_key)
  end

  @doc "Whether this file is an image."
  @spec image?(t()) :: boolean()
  def image?(%__MODULE__{kind: :image}), do: true
  def image?(%__MODULE__{}), do: false
end
