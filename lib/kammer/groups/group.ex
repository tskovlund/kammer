defmodule Kammer.Groups.Group do
  @moduledoc """
  A group within a community (SPEC §3).

  Groups carry the four visibility presets (exactly four — ADR 0004), the
  join/posting/comment policies, the irreversible sealed flag (ADR 0005),
  and the archive state. All permission questions about groups are answered
  by `Kammer.Authorization`, never here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}
  @type visibility() :: :private | :community | :public_link | :public_listed
  @type join_policy() :: :invite_only | :request_approval | :open
  @type posting_policy() :: :all_members | :admins_only
  @type comment_policy() :: :members | :members_and_guests | :off

  @visibilities [:private, :community, :public_link, :public_listed]
  @join_policies [:invite_only, :request_approval, :open]
  @posting_policies [:all_members, :admins_only]
  @comment_policies [:members, :members_and_guests, :off]

  # Per-group feature toggles (ADR 0016). The feed is not toggleable —
  # a group without a wall is a different product concept. New features
  # join @features and @toggleable_features but NOT @default_features:
  # they ship OFF by default, for new and existing groups alike.
  @features [:feed, :events, :files, :availability, :assignments]
  @toggleable_features [:events, :files, :availability, :assignments]
  @default_features [:feed, :events, :files]

  @slug_format ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "groups" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :visibility, Ecto.Enum, values: @visibilities, default: :community
    field :join_policy, Ecto.Enum, values: @join_policies, default: :open
    field :posting_policy, Ecto.Enum, values: @posting_policies, default: :all_members
    field :comment_policy, Ecto.Enum, values: @comment_policies, default: :members
    field :approval_queue, :boolean, default: false
    field :sealed, :boolean, default: false
    field :features, {:array, Ecto.Enum}, values: @features, default: @default_features
    field :archived_at, :utc_datetime
    field :ics_token, :string, redact: true
    field :storage_quota_bytes, :integer
    field :version_retention, :integer

    belongs_to :community, Kammer.Communities.Community
    has_many :memberships, Kammer.Groups.GroupMembership

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a group. The sealed flag can only be set here —
  at creation time — and is irreversible thereafter (SPEC §3, ADR 0005).
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(group, attrs) do
    group
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :visibility,
      :join_policy,
      :posting_policy,
      :comment_policy,
      :approval_queue,
      :sealed,
      :community_id
    ])
    |> validate_required([:name, :slug, :community_id])
    |> shared_validations()
  end

  @doc """
  Changeset for updating a group's settings. Never casts `sealed`
  (irreversible) or `community_id` (groups don't move between communities).
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(group, attrs) do
    group
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :visibility,
      :join_policy,
      :posting_policy,
      :comment_policy,
      :approval_queue,
      :version_retention
    ])
    |> validate_number(:version_retention, greater_than: 0)
    |> validate_required([:name, :slug])
    |> shared_validations()
  end

  @doc """
  Changeset for the feature toggles (ADR 0016). The feed is forced on;
  order is normalized so the column is canonical.
  """
  @spec features_changeset(t(), map()) :: Ecto.Changeset.t()
  def features_changeset(group, attrs) do
    group
    |> cast(attrs, [:features])
    |> update_change(:features, fn features ->
      Enum.filter(@features, fn feature ->
        feature == :feed or feature in features
      end)
    end)
  end

  @doc "All known features, in canonical order."
  @spec features() :: [atom()]
  def features, do: @features

  @doc "Features a group admin may turn on and off."
  @spec toggleable_features() :: [atom()]
  def toggleable_features, do: @toggleable_features

  @doc """
  Whether a feature is enabled for the group. Permission questions
  belong to `Kammer.Authorization` — this is the raw fact it consults.
  """
  @spec feature_enabled?(t(), atom()) :: boolean()
  def feature_enabled?(%__MODULE__{features: features}, feature), do: feature in features

  @doc """
  Changeset for archiving or unarchiving (SPEC §3: read-only, hidden from
  active lists, unarchivable by admins).
  """
  @spec archive_changeset(t(), DateTime.t() | nil) :: Ecto.Changeset.t()
  def archive_changeset(group, archived_at) do
    change(group, archived_at: archived_at)
  end

  defp shared_validations(changeset) do
    changeset
    |> validate_length(:name, min: 1, max: 100)
    |> update_change(:slug, &String.downcase/1)
    |> validate_length(:slug, min: 2, max: 60)
    |> validate_format(:slug, @slug_format,
      message: "may only contain lowercase letters, digits, and hyphens"
    )
    |> unique_constraint([:community_id, :slug])
  end

  @doc "Whether the group is archived."
  @spec archived?(t()) :: boolean()
  def archived?(%__MODULE__{archived_at: archived_at}), do: not is_nil(archived_at)

  @doc "The four visibility presets (exactly four — ADR 0004)."
  @spec visibilities() :: [visibility()]
  def visibilities, do: @visibilities

  @doc "All valid join policies."
  @spec join_policies() :: [join_policy()]
  def join_policies, do: @join_policies

  @doc "All valid posting policies."
  @spec posting_policies() :: [posting_policy()]
  def posting_policies, do: @posting_policies

  @doc "All valid comment policies."
  @spec comment_policies() :: [comment_policy()]
  def comment_policies, do: @comment_policies
end
