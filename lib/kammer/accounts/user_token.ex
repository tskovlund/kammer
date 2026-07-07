defmodule Kammer.Accounts.UserToken do
  @moduledoc """
  Persisted authentication tokens: revocable sessions (with the device's
  user agent for the devices page), single-use short-lived magic-link
  tokens, and email-change confirmations (SPEC §2).
  """

  use Ecto.Schema

  import Ecto.Query

  alias Kammer.Accounts.UserToken

  @type t() :: %__MODULE__{}

  @hash_algorithm :sha256
  @rand_size 32

  # It is very important to keep the magic link token expiry short,
  # since someone with access to the email may take over the account.
  @magic_link_validity_in_minutes 15
  @change_email_validity_in_days 7
  @session_validity_in_days 14
  # API device tokens (ADR 0014) live long — they are the API sibling
  # of browser sessions, revocable any time from the devices page.
  @device_validity_in_days 365
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
  not expired (after @session_validity_in_days).
  """
  @spec verify_session_token_query(binary()) :: {:ok, Ecto.Query.t()}
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
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
  the context is right, it is younger than #{@device_validity_in_days}
  days, and the account email hasn't changed since issuance.
  """
  @spec verify_device_token_query(String.t()) :: {:ok, Ecto.Query.t()} | :error
  def verify_device_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "api-device"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(@device_validity_in_days, "day"),
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
  database and if it has not expired (after @change_email_validity_in_days).
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
            where: token.inserted_at > ago(@change_email_validity_in_days, "day")

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
