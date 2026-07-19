defmodule Kammer.Legal.LegalPage do
  @moduledoc """
  An operator-editable legal page (SPEC §13): privacy policy or imprint.
  Publicly readable, one row per key.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "legal_pages" do
    field :key, :string
    field :content_markdown, :string, default: ""

    belongs_to :updated_by_user, Kammer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for editing a legal page's content.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(page, attrs) do
    page
    |> cast(attrs, [:content_markdown])
    |> validate_required([:key, :content_markdown])
    |> validate_length(:content_markdown, min: 1, max: 100_000)
    |> unique_constraint(:key)
  end
end
