defmodule Kammer.Notifications.PushSubscription do
  @moduledoc """
  A browser Web Push subscription (SPEC §1: Web Push via VAPID).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh_key, :string
    field :auth_key, :string

    belongs_to :user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for registering a subscription.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :p256dh_key, :auth_key, :user_id])
    |> validate_required([:endpoint, :p256dh_key, :auth_key, :user_id])
    |> validate_length(:endpoint, max: 2000)
    |> unique_constraint([:user_id, :endpoint])
  end
end
