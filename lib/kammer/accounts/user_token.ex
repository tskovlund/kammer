defmodule Kammer.Accounts.UserToken do
  @moduledoc """
  Persisted authentication tokens: revocable sessions (with the device's
  user agent for the devices page), single-use short-lived magic-link
  tokens, and email-change confirmations (SPEC §2).
  """

  use Ecto.Schema

  import Ecto.Query

  alias Kammer.Accounts.UserToken
  alias Kammer.Config

  @type t() :: %__MODULE__{}

  @hash_algorithm :sha256
  @rand_size 32

  # It is very important to keep the magic link token expiry short,
  # since someone with access to the email may take over the account.
  @magic_link_validity_in_minutes 15
  # Short sign-in codes (issue #177) ride in the same email as the
  # magic link and share its lifetime — one email, one expiry story
  # for the user. Codes carry only 40 bits of entropy, so unlike the
  # 32-byte tokens they are additionally scoped to the email they
  # were sent to and rate-limited at the exchange endpoint.
  @login_code_validity_in_minutes 15
  # Crockford base32 without lookalikes: no I, L, O (mapped from user
  # input by normalize_login_code/1) and no U (transcription safety).
  @login_code_alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  # session/device/change-email lifetimes are tier-2 deployment config
  # (ADR 0027, issue #234) — see Kammer.Config.session_validity_days/0,
  # api_device_validity_days/0, change_email_validity_days/0.
  # Passkey exchange tokens (ADR 0018) only bridge a WebAuthn assertion
  # verified inside a LiveView process to the controller action that
  # sets the session cookie (LiveView has no `conn` to do that itself)
  # — minutes, not the login-link's 15, since there is no email hop.
  @passkey_exchange_validity_in_minutes 2

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :user_agent, :string
    field :authenticated_at, :utc_datetime
    belongs_to :user, Kammer.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.

  The reason why we store session tokens in the database, even
  though Phoenix already provides a session cookie, is because
  Phoenix's default session cookies are not persisted, they are
  simply signed and potentially encrypted. This means they are
  valid indefinitely, unless you change the signing/encryption
  salt.

  Therefore, storing them allows individual user
  sessions to be expired. The token system can also be extended
  to store additional data, such as the device used for logging in.
  You could then use this information to display all valid sessions
  and devices in the UI and allow users to explicitly expire any
  session they deem invalid.
  """
  @spec build_session_token(Kammer.Accounts.User.t(), String.t() | nil) :: {binary(), t()}
  def build_session_token(user, user_agent \\ nil) do
    token = :crypto.strong_rand_bytes(@rand_size)
    authenticated_at = user.authenticated_at || DateTime.utc_now(:second)

    {token,
     %UserToken{
       token: token,
       context: "session",
       user_id: user.id,
       user_agent: truncate_user_agent(user_agent),
       authenticated_at: authenticated_at
     }}
  end

  defp truncate_user_agent(nil), do: nil
  defp truncate_user_agent(user_agent), do: String.slice(user_agent, 0, 255)

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any, along with the token's creation time.

  The token is valid if it matches the value in the database and it has
  not expired (after the configured session validity —
  `Kammer.Config.session_validity_days/0`).
  """
  @spec verify_session_token_query(binary()) :: {:ok, Ecto.Query.t()}
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(^Config.session_validity_days(), "day"),
        select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}

    {:ok, query}
  end

  @doc """
  Builds a token and its hash to be delivered to the user's email.

  The non-hashed token is sent to the user email while the
  hashed part is stored in the database. The original token cannot be reconstructed,
  which means anyone with read-only access to the database cannot directly use
  the token in the application to gain access. Furthermore, if the user changes
  their email in the system, the tokens sent to the previous email are no longer
  valid.

  Users can easily adapt the existing code to provide other types of delivery methods,
  for example, by phone numbers.
  """
  @spec build_email_token(Kammer.Accounts.User.t(), String.t()) :: {String.t(), t()}
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  @doc """
  Builds a long-lived API device token (ADR 0014): hashed at rest like
  email tokens — the cleartext travels with the API client, so a
  database leak must not mint credentials. `device_name` shows on the
  devices page beside browser sessions.
  """
  @spec build_device_token(Kammer.Accounts.User.t(), String.t() | nil) :: {String.t(), t()}
  def build_device_token(user, device_name) do
    {encoded_token, user_token} = build_hashed_token(user, "api-device", user.email)
    {encoded_token, %UserToken{user_token | user_agent: truncate_user_agent(device_name)}}
  end

  @doc """
  Verification query for an API device token: valid if the hash matches,
  the context is right, it is younger than the configured device
  validity (`Kammer.Config.api_device_validity_days/0`), and the
  account email hasn't changed since issuance.
  """
  @spec verify_device_token_query(String.t()) :: {:ok, Ecto.Query.t()} | :error
  def verify_device_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "api-device"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^Config.api_device_validity_days(), "day"),
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Builds a short single-use sign-in code (issue #177): #{length(@login_code_alphabet)}
  symbols × 8 characters = 40 bits, hashed at rest like every other
  emailed token so a database leak cannot mint credentials. The
  cleartext code goes into the same email as the magic link, for
  typing into the PWA on another device.
  """
  @spec build_login_code(Kammer.Accounts.User.t()) :: {String.t(), t()}
  def build_login_code(user) do
    code = generate_login_code()

    {code,
     %UserToken{
       token: :crypto.hash(@hash_algorithm, code),
       context: "login-code",
       sent_to: user.email,
       user_id: user.id
     }}
  end

  # 5 random bytes are exactly eight 5-bit groups — no partial symbol.
  defp generate_login_code do
    for <<symbol_index::5 <- :crypto.strong_rand_bytes(5)>>, into: "" do
      <<Enum.at(@login_code_alphabet, symbol_index)>>
    end
  end

  @doc """
  Verification query for a short sign-in code. Valid only when the
  hash matches, the code was sent to exactly the email the caller
  supplies (a code cannot be guessed against every account at once),
  the account email hasn't changed since issuance, and it is younger
  than #{@login_code_validity_in_minutes} minutes. Returns `{user, token}`.

  Input is normalized per Crockford base32 (case-insensitive; I/L read
  as 1, O as 0; separators dropped) so a hand-typed code survives the
  usual transcription slips.
  """
  @spec verify_login_code_query(String.t(), String.t()) :: {:ok, Ecto.Query.t()}
  def verify_login_code_query(email, code) do
    hashed_code = :crypto.hash(@hash_algorithm, normalize_login_code(code))

    query =
      from token in by_token_and_context_query(hashed_code, "login-code"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(^@login_code_validity_in_minutes, "minute"),
        where: token.sent_to == ^email,
        where: token.sent_to == user.email,
        select: {user, token}

    {:ok, query}
  end

  defp normalize_login_code(code) do
    code
    |> String.upcase()
    |> String.replace(["-", " "], "")
    |> String.replace("O", "0")
    |> String.replace(["I", "L"], "1")
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  If found, the query returns a tuple of the form `{user, token}`.

  The given token is valid if it matches its hashed counterpart in the
  database. This function also checks whether the token has expired. The context
  of a magic link token is always "login".
  """
  @spec verify_magic_link_token_query(String.t()) :: {:ok, Ecto.Query.t()} | :error
  def verify_magic_link_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "login"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^@magic_link_validity_in_minutes, "minute"),
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user_token found by the token, if any.

  This is used to validate requests to change the user
  email.
  The given token is valid if it matches its hashed counterpart in the
  database and if it has not expired (after the configured
  change-email validity — `Kammer.Config.change_email_validity_days/0`).
  The context must always start with "change:".
  """
  @spec verify_change_email_token_query(String.t(), String.t()) ::
          {:ok, Ecto.Query.t()} | :error
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(^Config.change_email_validity_days(), "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Builds a short-lived, single-use token handing a passkey login off
  from the LiveView process that verified it (no `conn`, so no way to
  set the session cookie) to the controller action that finalizes it.
  """
  @spec build_passkey_exchange_token(Kammer.Accounts.User.t()) :: {String.t(), t()}
  def build_passkey_exchange_token(user) do
    build_hashed_token(user, "passkey-exchange", nil)
  end

  @doc """
  Checks if a passkey exchange token is valid and returns its
  underlying lookup query. Valid if the hash matches and it is younger
  than #{@passkey_exchange_validity_in_minutes} minutes.
  """
  @spec verify_passkey_exchange_token_query(String.t()) :: {:ok, Ecto.Query.t()} | :error
  def verify_passkey_exchange_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "passkey-exchange"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^@passkey_exchange_validity_in_minutes, "minute"),
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
