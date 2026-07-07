defmodule Kammer.Newsletters.NewsletterSubscription do
  @moduledoc """
  A guest's subscription to a public group's feed (ADR 0013's
  email-only-identity pattern, extended): created only once the signed
  confirm link is followed, same as a guest RSVP or comment. Unlike
  those, a subscription isn't a nullable FK on an existing subject —
  it isn't about one post, it's about the group's feed as a whole, so
  it gets its own table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type cadence() :: :per_post | :daily | :weekly
  @type t() :: %__MODULE__{}

  @cadences [:per_post, :daily, :weekly]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "newsletter_subscriptions" do
    field :cadence, Ecto.Enum, values: @cadences, default: :per_post
    field :last_sent_at, :utc_datetime

    belongs_to :group, Kammer.Groups.Group
    belongs_to :guest_identity, Kammer.Guests.GuestIdentity

    timestamps(type: :utc_datetime)
  end

  @doc "Valid subscription cadences."
  @spec cadences() :: [cadence()]
  def cadences, do: @cadences

  @doc """
  Changeset for creating or updating a subscription. `group_id` and
  `guest_identity_id` are set programmatically, never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:cadence])
    |> validate_required([:cadence])
    |> unique_constraint([:group_id, :guest_identity_id])
  end
end
