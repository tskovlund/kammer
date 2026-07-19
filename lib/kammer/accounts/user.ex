defmodule Kammer.Accounts.User do
  @moduledoc """
  A user account.

  Kammer is passwordless (SPEC §2): users sign in with magic links sent to
  their email, optionally adding passkeys later. Email is the universal
  identity primitive; `display_name` is the only required base profile field
  (SPEC §4).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Kammer.Accounts.User
  alias Kammer.Validation

  @type t() :: %__MODULE__{}
  @type visibility() :: :hidden | :members | :admins
  @type feed_sort() :: :chronological | :activity

  @visibilities [:hidden, :members, :admins]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :email, :string
    field :display_name, :string
    field :locale, :string, default: "en"
    field :timezone, :string, default: "Etc/UTC"
    field :digest_frequency, Ecto.Enum, values: [:off, :daily, :weekly], default: :off
    field :last_digest_at, :utc_datetime
    field :instance_operator, :boolean, default: false
    field :ics_token, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    # Optional base profile fields (SPEC §4). Contact fields each carry
    # their own visibility since a phone number and a public email
    # address warrant different exposure; bio/pronouns are simple
    # opt-in text (blank means not shown — that's the whole control).
    field :bio, :string
    field :pronouns, :string
    field :contact_phone, :string
    field :contact_phone_visibility, Ecto.Enum, values: @visibilities, default: :hidden
    field :contact_email, :string
    field :contact_email_visibility, Ecto.Enum, values: @visibilities, default: :hidden
    field :contact_note, :string
    field :contact_note_visibility, Ecto.Enum, values: @visibilities, default: :hidden

    # ADR 0006: the only alternate feed ordering, opt-in, chronological
    # stays the default everywhere.
    field :feed_sort, Ecto.Enum, values: [:chronological, :activity], default: :chronological

    timestamps(type: :utc_datetime)
  end

  @doc """
  A changeset for registration: email plus display name — the only required
  base profile field.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  @spec registration_changeset(t(), map(), keyword()) :: Ecto.Changeset.t()
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :display_name])
    |> validate_email(opts)
    |> validate_display_name()
  end

  @doc """
  A user changeset for changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  @spec email_changeset(t(), map(), keyword()) :: Ecto.Changeset.t()
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  @doc """
  A changeset for profile settings: display name, interface language,
  timezone (SPEC §4 — language/timezone editable in settings, never demanded
  at onboarding), and the optional base profile fields (bio, pronouns,
  contact info with per-field visibility).
  """
  @spec settings_changeset(t(), map()) :: Ecto.Changeset.t()
  def settings_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :display_name,
      :locale,
      :timezone,
      :digest_frequency,
      :bio,
      :pronouns,
      :contact_phone,
      :contact_phone_visibility,
      :contact_email,
      :contact_email_visibility,
      :contact_note,
      :contact_note_visibility,
      :feed_sort
    ])
    |> validate_display_name()
    |> validate_inclusion(:locale, allowed_locales())
    |> validate_timezone()
    |> validate_length(:bio, max: 500)
    |> validate_length(:pronouns, max: 40)
    # The optional contact fields treat a blank submission as "clear it"
    # (blank means not shown, per the schema), so normalize whitespace-only
    # to nil for all three — consistently, and so contact_email's format
    # check below is skipped on an intentional clear rather than tripping
    # on an empty string.
    |> update_change(:contact_email, &blank_to_nil/1)
    |> update_change(:contact_phone, &blank_to_nil/1)
    |> update_change(:contact_note, &blank_to_nil/1)
    # contact_email is an email field, so it also takes the shared format
    # rule — otherwise a NUL here would pass straight to Postgres and 500
    # (issue #334, the same class as the primary :email). (contact_phone
    # and contact_note stay free-text, format-unvalidated.)
    |> Validation.validate_email_format(:contact_email,
      message: "must have the @ sign and no spaces"
    )
  end

  # Normalizes a blank (empty or whitespace-only) optional field to nil,
  # so an intentional "clear it" submission stores nothing (and, for a
  # validated field, skips the format validators — Ecto skips those for
  # nil) rather than storing or tripping on an empty/whitespace string.
  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> Validation.validate_email_format(:email, message: "must have the @ sign and no spaces")

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Kammer.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  defp validate_display_name(changeset) do
    changeset
    |> validate_required([:display_name])
    |> update_change(:display_name, &String.trim/1)
    |> Validation.validate_display_name_length(:display_name, 100)
  end

  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, timezone ->
      # Time zone validity is checked against the database the runtime knows.
      case DateTime.now(timezone) do
        {:ok, _now} -> []
        {:error, _reason} -> [timezone: "is not a known time zone"]
      end
    end)
  end

  defp allowed_locales do
    Application.get_env(:kammer, KammerWeb.Gettext, [])
    |> Keyword.get(:allowed_locales, ["en"])
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  @spec confirm_changeset(t()) :: Ecto.Changeset.t()
  def confirm_changeset(%User{} = user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end
end
