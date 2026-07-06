defmodule Kammer.Communities.Community do
  @moduledoc """
  A community — the tenant unit (SPEC §3). One instance hosts many
  communities; every scoped table carries `community_id`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @slug_format ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
  @accent_color_format ~r/^#[0-9a-fA-F]{6}$/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "communities" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :accent_color, :string, default: "#3E6B48"
    field :default_locale, :string, default: "en"
    field :listed_on_instance, :boolean, default: false
    field :require_real_names, :boolean, default: false
    field :storage_quota_bytes, :integer
    field :version_retention, :integer

    has_many :memberships, Kammer.Communities.CommunityMembership
    has_many :groups, Kammer.Groups.Group

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating and updating a community.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(community, attrs) do
    community
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :accent_color,
      :default_locale,
      :listed_on_instance,
      :require_real_names
    ])
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 100)
    |> update_change(:slug, &String.downcase/1)
    |> validate_length(:slug, min: 2, max: 60)
    |> validate_format(:slug, @slug_format,
      message: "may only contain lowercase letters, digits, and hyphens"
    )
    |> validate_exclusion(:slug, reserved_slugs(), message: "is reserved")
    |> validate_format(:accent_color, @accent_color_format,
      message: "must be a hex color like #3E6B48"
    )
    |> validate_inclusion(:default_locale, ["en", "da"])
    |> unique_constraint(:slug)
  end

  defp reserved_slugs do
    ~w(new admin settings api instance setup users dev public assets)
  end
end
