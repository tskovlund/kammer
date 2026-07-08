defmodule Kammer.Notifications.NotificationPreference do
  @moduledoc """
  Per-user, per-group notification level (SPEC §9):
  everything / highlights / mentions-only / muted.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}
  @type level() :: :everything | :highlights | :mentions_only | :muted

  @levels [:everything, :highlights, :mentions_only, :muted]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "notification_preferences" do
    field :level, Ecto.Enum, values: @levels, default: :highlights

    belongs_to :user, Kammer.Accounts.User
    belongs_to :group, Kammer.Groups.Group

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for setting a preference.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [:level, :user_id, :group_id])
    |> validate_required([:level, :user_id, :group_id])
    |> unique_constraint([:user_id, :group_id])
  end
end
