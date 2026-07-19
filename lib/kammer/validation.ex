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

  # `\A…\z` (not `^…$`, which admit a trailing newline) plus the explicit
  # control-char exclusion (`\x00-\x1F`, `\x7F`) keep out bytes no email
  # should hold — most critically a NUL, which passes a naive format check
  # but then raises `Postgrex.Error` at the database write (Postgres text
  # columns reject it), turning a crafted JSON body into an unhandled 500
  # (issue #334). `\s` (ASCII whitespace) and the C0/DEL range together
  # exclude every ASCII control and whitespace byte; non-ASCII bytes still
  # pass, so Unicode local parts and IDN hosts are unaffected.
  @email_format ~r/\A[^@,;\s\x00-\x1F\x7F]+@[^@,;\s\x00-\x1F\x7F]+\z/

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
  Whether `value` matches the same format rule `validate_email_format/3`
  enforces. The guard for a *raw* email param that reaches a query
  without a changeset — a lookup by email (sign-in, login-code exchange,
  instance ban) — so a control character can't ride a `where email = ?`
  into Postgres and raise a 500 (issue #334). Total over non-binaries, so
  a nil or wrongly-typed value is simply `false` (no match), not a crash.

  Deliberately as strict as the write rule (rejects every control char,
  not only the NUL that actually 500s), so a malformed address is treated
  the same on the way in and the way out. The tightened write path means
  no new row can hold one; a *pre-existing* control-char address (only
  the old, looser write rule could have stored one) would read as
  not-found here rather than 500 — the right trade until a data pass
  normalizes any such legacy rows.
  """
  @spec email_format?(term()) :: boolean()
  def email_format?(value) when is_binary(value), do: value =~ @email_format
  def email_format?(_value), do: false

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
