defmodule Kammer.Files.Folder do
  @moduledoc """
  A folder in a file space (SPEC §7): shallow tree per owning scope
  (community or group). Permissions are presets only — per-folder
  overrides restrict read/write to admins; subfolders inherit from
  parents; no per-user ACLs (ADR 0009). System folders (e.g. "Feed
  uploads") are auto-created and cannot be renamed or deleted.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}
  @type override() :: :inherit | :admins_only

  @overrides [:inherit, :admins_only]
  @maximum_depth 4

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "folders" do
    field :name, :string
    field :read_override, Ecto.Enum, values: @overrides, default: :inherit
    field :write_override, Ecto.Enum, values: @overrides, default: :inherit
    field :system_key, :string

    belongs_to :community, Kammer.Communities.Community
    belongs_to :group, Kammer.Groups.Group
    belongs_to :parent_folder, Kammer.Files.Folder

    has_many :subfolders, Kammer.Files.Folder, foreign_key: :parent_folder_id
    has_many :stored_files, Kammer.Files.StoredFile

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a folder.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [
      :name,
      :read_override,
      :write_override,
      :community_id,
      :group_id,
      :parent_folder_id
    ])
    |> validate_required([:name, :community_id])
    |> validate_length(:name, min: 1, max: 100)
  end

  @doc "Valid preset overrides."
  @spec overrides() :: [override()]
  def overrides, do: @overrides

  @doc "Maximum folder nesting depth — the tree stays shallow (SPEC §7)."
  @spec maximum_depth() :: pos_integer()
  def maximum_depth, do: @maximum_depth
end
