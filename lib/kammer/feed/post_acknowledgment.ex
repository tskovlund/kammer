defmodule Kammer.Feed.PostAcknowledgment do
  @moduledoc """
  An explicit acknowledgment tap on an acknowledgment-required post
  (SPEC §5). Deliberate and consent-based — Kammer has no passive
  "Seen by" tracking.
  """

  use Ecto.Schema

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "post_acknowledgments" do
    belongs_to :post, Kammer.Feed.Post
    belongs_to :user, Kammer.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
