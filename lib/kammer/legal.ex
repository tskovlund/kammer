defmodule Kammer.Legal do
  @moduledoc """
  Legal pages (SPEC §13): a privacy-policy and imprint page per instance,
  publicly readable, editable by instance operators. Until an operator
  publishes their own text, visitors see a built-in template and
  operators see a reminder to replace it.
  """

  use Gettext, backend: KammerWeb.Gettext

  alias Kammer.Accounts.User
  alias Kammer.Authorization
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
    # The unpersisted template carries the sentinel version 0 — strictly
    # below any published row (those start at 1), so an operator editing the
    # template can never match-and-clobber a row a concurrent publish created.
    Repo.get_by(LegalPage, key: key) ||
      %LegalPage{key: key, content_markdown: template(key), lock_version: 0}
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

  Optimistic concurrency (#276 item 4): `expected_version` is the
  `lock_version` the editor last read. A first publish (no row yet) ignores
  it — a concurrent first publish is caught by the unique key. An edit of an
  existing row refuses a stale write with `{:error, :stale}` (→ 409) when the
  stored version has moved on, so two operators editing at once never silently
  last-write-win; the loser reloads.
  """
  @spec upsert_page(User.t(), String.t(), map(), integer()) ::
          {:ok, LegalPage.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :stale}
  def upsert_page(%User{} = actor, key, attrs, expected_version) when key in @keys do
    if Authorization.instance_operator?(actor) do
      case Repo.get_by(LegalPage, key: key) do
        nil -> first_publish(key, attrs, actor)
        %LegalPage{} = existing -> update_published(existing, attrs, actor, expected_version)
      end
    else
      {:error, :unauthorized}
    end
  end

  # No row yet: the built-in template still shows. Insert at version 1 (the
  # template reports 0, so published rows stay strictly ahead).
  defp first_publish(key, attrs, actor) do
    %LegalPage{key: key}
    |> LegalPage.changeset(attrs)
    |> Ecto.Changeset.put_change(:updated_by_user_id, actor.id)
    |> Ecto.Changeset.put_change(:lock_version, 1)
    |> Repo.insert()
    |> case do
      {:ok, page} -> {:ok, page}
      {:error, %Ecto.Changeset{} = changeset} -> insert_error(changeset)
    end
  end

  # A truly simultaneous first publish — both callers saw no row, both INSERT —
  # trips the unique key on `:key` for the loser. That's a conflict to reload
  # from, not a validation error, so fold it into the same stale result an edit
  # race gets (a `:key` error here is only ever the unique constraint: `:key`
  # is set programmatically and isn't cast, so `validate_required` can't fire
  # on it). This TOCTOU race can't be reproduced deterministically in the async
  # sandbox, so it is read-verified against `unique_index(:legal_pages, [:key])`.
  defp insert_error(changeset) do
    if Keyword.has_key?(changeset.errors, :key),
      do: {:error, :stale},
      else: {:error, changeset}
  end

  # An existing row: guard the write against the version the *caller last read*,
  # not the row's current version. Forcing the struct's `lock_version` to
  # `expected_version` makes `optimistic_lock` emit `WHERE lock_version =
  # expected_version`, so the UPDATE lands only if the stored version still
  # matches what the editor saw. If another operator saved in between — or the
  # caller's version is already behind — the UPDATE matches no row and Ecto
  # raises `StaleEntryError`, folded to a neutral `:stale` (→ 409). One
  # mechanism covers both the already-behind case and the read→write race.
  # `updated_by_user_id` is set programmatically, never cast (CONVENTIONS).
  defp update_published(existing, attrs, actor, expected_version) do
    %{existing | lock_version: expected_version}
    |> LegalPage.changeset(attrs)
    |> Ecto.Changeset.put_change(:updated_by_user_id, actor.id)
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
  rescue
    Ecto.StaleEntryError -> {:error, :stale}
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
