defmodule Kammer.Audit.AuditEvent do
  @moduledoc """
  One append-only record of an admin/operator action (SPEC §11): role
  changes, bans, deletions, settings changes, and community-admin
  overrides into groups. `summary` is precomputed in plain language at
  write time so the record stays readable after the row it describes
  is gone — the log must never depend on a live join.
  """

  use Ecto.Schema

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "audit_events" do
    field :action, :string
    field :summary, :string
    field :metadata, :map, default: %{}

    belongs_to :community, Kammer.Communities.Community
    belongs_to :actor_user, Kammer.Accounts.User

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end
