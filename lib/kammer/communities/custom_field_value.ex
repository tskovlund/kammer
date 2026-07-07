defmodule Kammer.Communities.CustomFieldValue do
  @moduledoc """
  One member's answer to one community-defined custom field (SPEC §4).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "custom_field_values" do
    field :value, :string

    belongs_to :custom_field, Kammer.Communities.CustomField
    belongs_to :user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for setting a member's value for a custom field.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(custom_field_value, attrs) do
    custom_field_value
    |> cast(attrs, [:custom_field_id, :user_id, :value])
    |> validate_required([:custom_field_id, :user_id, :value])
    |> validate_length(:value, max: 200)
    |> unique_constraint([:custom_field_id, :user_id])
  end
end
