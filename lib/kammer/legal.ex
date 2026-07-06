defmodule Kammer.Legal do
  @moduledoc """
  Legal pages (SPEC §13): a privacy-policy and imprint page per instance,
  publicly readable, editable by instance operators. Until an operator
  publishes their own text, visitors see a built-in template and
  operators see a reminder to replace it.
  """

  use Gettext, backend: KammerWeb.Gettext

  alias Kammer.Accounts.User
  alias Kammer.Legal.LegalPage
  alias Kammer.Repo

  @keys ~w(privacy imprint)

  @doc "The valid legal page keys."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc "Whether `key` names a legal page."
  @spec valid_key?(String.t()) :: boolean()
  def valid_key?(key), do: key in @keys

  @doc """
  The page for `key` — the stored version, or an unpersisted page holding
  the built-in template.
  """
  @spec get_page(String.t()) :: LegalPage.t()
  def get_page(key) when key in @keys do
    Repo.get_by(LegalPage, key: key) ||
      %LegalPage{key: key, content_markdown: template(key)}
  end

  @doc """
  Whether an operator has published their own text for `key`. Until then
  the built-in template shows and operators are nagged to replace it.
  """
  @spec published?(String.t()) :: boolean()
  def published?(key) when key in @keys do
    Repo.get_by(LegalPage, key: key) != nil
  end

  @doc """
  Creates or updates the page for `key`. Instance operators only.
  """
  @spec upsert_page(User.t(), String.t(), map()) ::
          {:ok, LegalPage.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def upsert_page(%User{instance_operator: true} = actor, key, attrs) when key in @keys do
    page = Repo.get_by(LegalPage, key: key) || %LegalPage{key: key}

    page
    |> LegalPage.changeset(Map.put(attrs, "updated_by_user_id", actor.id))
    |> Repo.insert_or_update()
  end

  def upsert_page(%User{}, key, _attrs) when key in @keys, do: {:error, :unauthorized}

  @doc """
  Returns a changeset for the legal page edit form.
  """
  @spec change_page(LegalPage.t(), map()) :: Ecto.Changeset.t()
  def change_page(%LegalPage{} = page, attrs \\ %{}) do
    LegalPage.changeset(page, attrs)
  end

  @doc """
  The localized display title for a page key.
  """
  @spec title(String.t()) :: String.t()
  def title("privacy"), do: gettext("Privacy policy")
  def title("imprint"), do: gettext("Imprint")

  # Built-in templates (SPEC §13). Deliberately written as fill-in
  # scaffolds so an instance never ships someone else's legal text.
  defp template("privacy") do
    gettext("""
    _This is a template. The instance operator has not yet published a privacy policy — the notes below describe what Kammer itself stores._

    ## What this instance stores

    - **Account data**: your email address, display name, and preferred language.
    - **Content you create**: posts, comments, reactions, poll votes, RSVPs, and uploaded files, kept until you or a moderator deletes them (deleted content is purged permanently after 30 days).
    - **Sessions**: signed-in devices, including browser information, so you can review and revoke them.

    ## What this instance does not do

    - No advertising, no tracking pixels, no analytics sent to third parties.
    - Uploaded images are re-encoded and stripped of metadata (such as location data) on upload.

    ## Contact

    _[Operator: add who runs this instance, how to reach you, and any additional processing you do — for example your email provider or file storage location.]_
    """)
  end

  defp template("imprint") do
    gettext("""
    _This is a template. The instance operator has not yet published an imprint._

    ## Responsible for this instance

    _[Operator: add your name or organisation, a contact address, and an email address. Depending on where you operate, an imprint may be legally required.]_
    """)
  end
end
