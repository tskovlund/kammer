defmodule Kammer.Notifications.Notification do
  @moduledoc """
  An in-app notification (SPEC §9): who it is for, what kind, who acted,
  and which post/comment/event it points at.
  """

  use Ecto.Schema

  @type t() :: %__MODULE__{}

  @kinds [
    :post,
    :mention,
    :reply,
    :acknowledgment_required,
    :event_created,
    :event_reminder
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "notifications" do
    field :kind, Ecto.Enum, values: @kinds
    field :read_at, :utc_datetime

    belongs_to :user, Kammer.Accounts.User
    belongs_to :community, Kammer.Communities.Community
    belongs_to :group, Kammer.Groups.Group
    belongs_to :actor_user, Kammer.Accounts.User
    belongs_to :post, Kammer.Feed.Post
    belongs_to :comment, Kammer.Feed.Comment
    belongs_to :event, Kammer.Events.Event

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
