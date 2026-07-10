defmodule Kammer.Communities.InstanceBookmark do
  @moduledoc """
  A per-user cross-instance bookmark ("My other servers", SPEC §3): a smart
  bookmark to another Kammer instance the user belongs to. Plain navigation
  to the other origin — no federation, no sync.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Kammer.Validation

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "instance_bookmarks" do
    field :name, :string
    field :url, :string
    field :position, :integer, default: 0

    belongs_to :user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a bookmark. Only http(s) URLs are
  accepted.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(bookmark, attrs) do
    bookmark
    |> cast(attrs, [:name, :url, :position])
    |> validate_required([:name, :url])
    |> validate_length(:name, max: 100)
    |> validate_length(:url, max: 500)
    |> Validation.validate_http_url(:url)
  end
end
