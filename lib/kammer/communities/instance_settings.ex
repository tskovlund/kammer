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

    field :storage_policy, Ecto.Enum, values: [:unmetered, :quota], default: :unmetered
    field :setup_completed_at, :utc_datetime

    # SPEC §9 / ADR 0011: strips post content from digest emails when on.
    # Per-event notification emails never carried content to begin with,
    # so this only changes what Kammer.Digests renders.
    field :content_minimized_emails, :boolean, default: false

    # Written by Kammer.UpdateCheck, not by the settings form — never
    # cast here (see the Ecto guideline on programmatically-set fields).
    field :latest_known_version, :string
    field :latest_known_release_url, :string
    field :update_checked_at, :utc_datetime

    belongs_to :demo_community, Kammer.Communities.Community

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
      :storage_policy,
      :setup_completed_at,
      :content_minimized_emails
    ])
    |> validate_inclusion(:default_locale, ["en", "da"])
    |> unique_constraint(:singleton_guard)
  end
end
