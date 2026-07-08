defmodule Kammer.Communities.CustomField do
  @moduledoc """
  A community-defined profile field (SPEC §4): "Instrument", "Section",
  "Dietary needs" — the fields that turn the member directory into the
  band roster. Admin-set visibility (members / admins-only) and an
  optional `required` flag; required fields hard-block at join, and
  making an existing field required nags already-joined members
  instead of locking them out (`Kammer.Communities.missing_required_custom_fields/2`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}
  @type field_type() :: :text | :single_select
  @type visibility() :: :members | :admins

  @field_types [:text, :single_select]
  @visibilities [:members, :admins]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "custom_fields" do
    field :label, :string
    field :field_type, Ecto.Enum, values: @field_types, default: :text
    field :options, {:array, :string}, default: []
    field :visibility, Ecto.Enum, values: @visibilities, default: :members
    field :required, :boolean, default: false
    field :position, :integer, default: 0

    belongs_to :community, Kammer.Communities.Community

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a custom field.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(custom_field, attrs) do
    custom_field
    |> cast(attrs, [
      :community_id,
      :label,
      :field_type,
      :options,
      :visibility,
      :required,
      :position
    ])
    |> validate_required([:community_id, :label, :field_type, :visibility])
    |> validate_length(:label, max: 80)
    |> update_change(:options, fn options -> Enum.reject(options, &(&1 in [nil, ""])) end)
    |> validate_options()
  end

  defp validate_options(changeset) do
    if get_field(changeset, :field_type) == :single_select and
         get_field(changeset, :options, []) == [] do
      add_error(changeset, :options, "must list at least one option")
    else
      changeset
    end
  end
end
