defmodule Kammer.Communities.InstanceSettings do
  @moduledoc """
  Singleton row of instance-level settings (SPEC §13): who may create
  communities, instance name, default locale, and whether first-run setup
  has completed. Env values overlay these at read time — env always wins.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @community_creation_policies [:operators_only, :any_user]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "instance_settings" do
    field :singleton_guard, :integer, default: 1
    field :instance_name, :string
    field :default_locale, :string, default: "en"

    field :community_creation_policy, Ecto.Enum,
      values: @community_creation_policies,
      default: :operators_only

    field :setup_completed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for updating instance settings.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :instance_name,
      :default_locale,
      :community_creation_policy,
      :setup_completed_at
    ])
    |> validate_inclusion(:default_locale, ["en", "da"])
    |> unique_constraint(:singleton_guard)
  end

  @doc "All valid community-creation policies."
  @spec community_creation_policies() :: [atom()]
  def community_creation_policies, do: @community_creation_policies
end
