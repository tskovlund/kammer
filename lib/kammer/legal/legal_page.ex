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

    # Optimistic-concurrency version (#276 item 4). No schema default on
    # purpose: the only unpersisted struct is the template, and `Kammer.Legal`
    # stamps its sentinel 0 explicitly there — every *persisted* row's version
    # comes from `first_publish` (writes 1) or `optimistic_lock` (increments),
    # so a published row is always ≥1, strictly ahead of the template. A raw
    # insert that forgets to set it hits NOT NULL and fails loudly rather than
    # creating a version-0 published row that could collide with the template.
    field :lock_version, :integer

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
