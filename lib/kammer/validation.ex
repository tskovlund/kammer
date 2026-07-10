defmodule Kammer.Validation do
  @moduledoc """
  Shared changeset validators for fields duplicated across every
  contact-only actor in the product: guest identities, newsletter
  subscribers, and event/post guest requests, plus registered users.
  Deliberately narrow — just the format/length rules, not
  normalization (e.g. downcasing email), since not every caller wants
  the same normalization.
  """

  import Ecto.Changeset

  @email_format ~r/^[^@,;\s]+@[^@,;\s]+$/

  @doc """
  Validates `field` is a well-formed email address, at most 160
  characters. Accepts the same options as `validate_format/4` (e.g.
  `:message`).
  """
  @spec validate_email_format(Ecto.Changeset.t(), atom(), keyword()) :: Ecto.Changeset.t()
  def validate_email_format(changeset, field \\ :email, opts \\ []) do
    changeset
    |> validate_format(field, @email_format, opts)
    |> validate_length(field, max: 160)
  end

  @doc """
  Validates `field` is a non-blank display name of at most `max`
  characters (120 by default).
  """
  @spec validate_display_name_length(Ecto.Changeset.t(), atom(), pos_integer()) ::
          Ecto.Changeset.t()
  def validate_display_name_length(changeset, field \\ :display_name, max \\ 120) do
    validate_length(changeset, field, min: 1, max: max)
  end

  # An anchored scheme allowlist, not a full URL parser, on purpose
  # (issue #247): the security property of a raw `<a href>` is decided
  # entirely by the scheme, and anything that survives the trim and
  # still starts `http(s)://<host char>` can only ever parse as
  # http(s) in a browser. Full RFC-3986 parsing (`URI.new/1`) was tried
  # first and over-rejected real-world values browsers accept — IDN
  # hosts (`https://øl.dk`, this is a Danish-facing product) and maps
  # URLs with unencoded spaces — while still accepting values the
  # client-side counterpart (`safeHttpUrl` in the PWA) rejected. One
  # regex, mirrored on both sides, keeps the two guards aligned. Not
  # byte-for-byte identical: the trim/whitespace semantics differ on
  # exotic Unicode whitespace (U+FEFF, U+0085, NBSP), but every such
  # divergence fails closed — a value one side rejects renders as
  # plain text, never as an executable link.
  @http_url ~r|^https?://[^\s/]|i

  @doc """
  Validates `field`, when present, is an `http`/`https` URL. Rejects
  `javascript:`, `data:`, and every other scheme a raw `<a href>`
  would execute in-origin (issue #247) — `rel="noopener noreferrer"`
  does not neutralize those. Absent/nil values pass (Ecto skips
  validators for them); pair with `validate_required/2` if the field
  is mandatory.
  """
  @spec validate_http_url(Ecto.Changeset.t(), atom(), keyword()) :: Ecto.Changeset.t()
  def validate_http_url(changeset, field, opts \\ []) do
    message = Keyword.get(opts, :message, "must be a valid http(s) URL")

    validate_change(changeset, field, fn _field, value ->
      if http_url?(value), do: [], else: [{field, message}]
    end)
  end

  @doc """
  Whether `value` is an `http`/`https` URL by the same rule
  `validate_http_url/3` enforces. The render-side guard for stored
  values that predate that validation or arrived through another
  write path (issue #247) — total over `nil` so call sites can pass
  a nullable field straight in.
  """
  @spec http_url?(String.t() | nil) :: boolean()
  def http_url?(value) when is_binary(value), do: String.trim(value) =~ @http_url
  def http_url?(_value), do: false
end
