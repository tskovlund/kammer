defmodule Kammer.Accounts do
  @moduledoc """
  Identity and authentication (SPEC §2).

  Kammer is passwordless: users register and sign in with single-use,
  short-lived magic links delivered by email, rate-limited per email and
  per IP. Sessions are long-lived and individually revocable from the
  devices page.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.{User, UserNotifier, UserPasskey, UserToken}
  alias Kammer.RateLimit
  alias Kammer.Repo

  ## Database getters

  @doc """
  Locks the user's row (`FOR UPDATE`) inside the caller's transaction
  and returns their current email, or `nil` if the account vanished
  concurrently. The serialization point every ban-sensitive write
  shares: the ban paths, membership adds, and community creation all
  take this lock first so ban-vs-join/create/ban races serialize
  instead of interleaving (issues #170/#171/#172).
  """
  @spec lock_user_email(User.t()) :: String.t() | nil
  def lock_user_email(%User{id: user_id}) do
    Repo.one(
      from(user in User, where: user.id == ^user_id, lock: "FOR UPDATE", select: user.email)
    )
  end

  @doc """
  Gets a user by email, or `nil`.
  """
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a single user, raising `Ecto.NoResultsError` if absent.
  """
  @spec get_user!(Ecto.UUID.t()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user from an email and display name — the only required base
  profile field (SPEC §4). Rate-limited by client IP (SPEC §11) when
  `:ip` is given — mass-account creation from one address, not a single
  legitimate signup, is what this guards against.
  """
  @spec register_user(map(), keyword()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | :rate_limited}
  def register_user(attrs, opts \\ []) do
    case RateLimit.hit_signup_ip(Keyword.get(opts, :ip)) do
      {:allow, _count} ->
        %User{}
        |> User.registration_changeset(attrs)
        |> Repo.insert()

      {:deny, _retry_after} ->
        {:error, :rate_limited}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for user registration.
  """
  @spec change_user_registration(User.t(), map(), keyword()) :: Ecto.Changeset.t()
  def change_user_registration(%User{} = user, attrs \\ %{}, opts \\ []) do
    User.registration_changeset(user, attrs, opts)
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  @spec sudo_mode?(User.t(), integer()) :: boolean()
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: timestamp}, minutes)
      when is_struct(timestamp, DateTime) do
    DateTime.after?(timestamp, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Kammer.Accounts.User.email_changeset/3` for a list of supported options.
  """
  @spec change_user_email(User.t(), map(), keyword()) :: Ecto.Changeset.t()
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for the profile settings (display name,
  language, timezone).
  """
  @spec change_user_settings(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_settings(%User{} = user, attrs \\ %{}) do
    User.settings_changeset(user, attrs)
  end

  @doc """
  Updates display name, language, timezone, and the optional base
  profile fields (bio, pronouns, contact info).
  """
  @spec update_user_settings(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_settings(%User{} = user, attrs) do
    user
    |> User.settings_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  A user's contact fields (phone, public email, other) the given
  community-role viewer is allowed to see (SPEC §4), as `{key, value}`
  pairs. `:hidden` fields never appear, regardless of role.
  """
  @spec visible_contact_fields(User.t(), Kammer.Communities.CommunityMembership.role() | nil) ::
          [{:phone | :email | :note, String.t()}]
  def visible_contact_fields(%User{} = user, viewer_role) do
    [
      {:phone, user.contact_phone, user.contact_phone_visibility},
      {:email, user.contact_email, user.contact_email_visibility},
      {:note, user.contact_note, user.contact_note_visibility}
    ]
    |> Enum.filter(fn {_key, value, visibility} ->
      value not in [nil, ""] and contact_visible?(visibility, viewer_role)
    end)
    |> Enum.map(fn {key, value, _visibility} -> {key, value} end)
  end

  defp contact_visible?(:hidden, _role), do: false
  defp contact_visible?(:members, role), do: role in [:owner, :admin, :member]
  defp contact_visible?(:admins, role), do: role in [:owner, :admin]

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  @spec update_user_email(User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  ## Session

  @doc """
  Generates a session token, recording the requesting device's user agent
  for the devices page.
  """
  @spec generate_user_session_token(User.t(), String.t() | nil) :: binary()
  def generate_user_session_token(user, user_agent \\ nil) do
    {token, user_token} = UserToken.build_session_token(user, user_agent)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise
  `nil` is returned.
  """
  @spec get_user_by_session_token(binary()) :: {User.t(), DateTime.t()} | nil
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  # The revocable-credential contexts a user manages on the devices
  # surface (issue #174): browser sessions and long-lived API device
  # tokens. Single-use exchange tokens (magic links, login codes,
  # passkey handoffs) are not devices.
  @device_contexts ["session", "api-device"]

  @doc """
  Lists every credential that can act as this account — browser
  sessions and API device tokens alike (SPEC §2, issue #174) — newest
  first. Both the devices page and the API device listing read from
  here, so an api-device token can never be invisible to its owner.
  """
  @spec list_user_devices(User.t()) :: [UserToken.t()]
  def list_user_devices(%User{} = user) do
    Repo.all(
      from(token in UserToken,
        where: token.user_id == ^user.id and token.context in ^@device_contexts,
        order_by: [desc: token.inserted_at]
      )
    )
  end

  @doc """
  Revokes one of the user's devices (browser session or API device
  token) by token id. Scoped to the given user so one user can never
  revoke another's; a foreign or unknown id reads as `{:error,
  :not_found}`. Returns the deleted token so the web layer can sever
  live sockets riding it (issue #174).
  """
  @spec revoke_user_device(User.t(), Ecto.UUID.t()) ::
          {:ok, UserToken.t()} | {:error, :not_found}
  def revoke_user_device(%User{} = user, token_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(token_id),
         %UserToken{} = token <-
           Repo.one(
             from(token in UserToken,
               where:
                 token.id == ^uuid and token.user_id == ^user.id and
                   token.context in ^@device_contexts
             )
           ),
         # Concurrent revokes race on this delete; the loser reads as
         # already-gone rather than a StaleEntryError 500.
         {1, _deleted} <- Repo.delete_all(from(t in UserToken, where: t.id == ^token.id)) do
      {:ok, token}
    else
      _missing -> {:error, :not_found}
    end
  end

  ## Passkeys (ADR 0018, SPEC §16): WebAuthn credentials, registered
  ## after first login. Sign-in is usernameless — no `allow_credentials`
  ## is set on the authentication challenge, so the browser offers every
  ## resident credential it holds for this origin, and the returned
  ## credential id (unique instance-wide) identifies the user. This
  ## context stays free of the web layer: callers pass `origin`
  ## (`KammerWeb.Endpoint.url/0`) rather than it being read here.

  @doc """
  Starts a passkey registration ceremony for the given user.
  """
  @spec new_passkey_registration_challenge(User.t(), String.t()) :: Wax.Challenge.t()
  def new_passkey_registration_challenge(%User{}, origin) do
    Wax.new_registration_challenge(origin: origin, rp_id: :auto)
  end

  @doc """
  Verifies and stores a newly registered passkey against the challenge
  `new_passkey_registration_challenge/2` returned.
  """
  @spec register_passkey(User.t(), binary(), String.t(), Wax.Challenge.t(), String.t() | nil) ::
          {:ok, UserPasskey.t()} | {:error, term()}
  def register_passkey(user, attestation_object, client_data_json, challenge, nickname \\ nil)

  def register_passkey(%User{} = user, attestation_object, client_data_json, challenge, nickname) do
    with {:ok, {auth_data, _attestation_result}} <-
           Wax.register(attestation_object, client_data_json, challenge) do
      credential = auth_data.attested_credential_data

      %UserPasskey{user_id: user.id}
      |> Ecto.Changeset.change(
        credential_id: credential.credential_id,
        public_key_cose: :erlang.term_to_binary(credential.credential_public_key),
        aaguid: Wax.AuthenticatorData.get_aaguid(auth_data),
        nickname: nickname
      )
      |> Ecto.Changeset.unique_constraint(:credential_id)
      |> Repo.insert()
    end
  end

  @doc """
  The user's registered passkeys, newest first.
  """
  @spec list_passkeys(User.t()) :: [UserPasskey.t()]
  def list_passkeys(%User{} = user) do
    Repo.all(
      from(passkey in UserPasskey,
        where: passkey.user_id == ^user.id,
        order_by: [desc: passkey.inserted_at]
      )
    )
  end

  @doc """
  Deletes one of the user's passkeys. Scoped to the given user so one
  user can never delete another's.
  """
  @spec delete_passkey(User.t(), Ecto.UUID.t()) :: :ok
  def delete_passkey(%User{} = user, passkey_id) do
    Repo.delete_all(
      from(passkey in UserPasskey,
        where: passkey.id == ^passkey_id and passkey.user_id == ^user.id
      )
    )

    :ok
  end

  @doc """
  Starts a usernameless passkey authentication ceremony.
  """
  @spec new_passkey_authentication_challenge(String.t()) :: Wax.Challenge.t()
  def new_passkey_authentication_challenge(origin) do
    Wax.new_authentication_challenge(origin: origin, rp_id: :auto)
  end

  @doc """
  Verifies a passkey authentication assertion and returns the user it
  identifies. Updates `sign_count` (clone detection per WebAuthn §7.2,
  tolerated at a standing `0` — most platform authenticators never
  increment it) and `last_used_at` on success.
  """
  @spec login_user_by_passkey(binary(), binary(), binary(), String.t(), Wax.Challenge.t()) ::
          {:ok, User.t()} | {:error, :not_found | term()}
  def login_user_by_passkey(credential_id, auth_data_bin, sig, client_data_json, challenge) do
    with %UserPasskey{} = passkey <- Repo.get_by(UserPasskey, credential_id: credential_id),
         cose_key = :erlang.binary_to_term(passkey.public_key_cose, [:safe]),
         {:ok, auth_data} <-
           Wax.authenticate(credential_id, auth_data_bin, sig, client_data_json, challenge, [
             {credential_id, cose_key}
           ]) do
      record_passkey_use(passkey, auth_data.sign_count)
      {:ok, get_user!(passkey.user_id)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # A standing 0 is normal (most passkey authenticators never
  # increment it); anything else must strictly increase, or the
  # credential may have been cloned. Either way the sign-in itself
  # already succeeded — this only updates bookkeeping.
  defp record_passkey_use(passkey, new_sign_count) do
    if new_sign_count == 0 or new_sign_count > passkey.sign_count do
      passkey
      |> Ecto.Changeset.change(
        sign_count: new_sign_count,
        last_used_at: DateTime.utc_now(:second)
      )
      |> Repo.update!()
    end

    :ok
  end

  @doc """
  Mints the short-lived token that hands a passkey login off to
  `login_user_by_passkey_exchange_token/1` (see ADR 0018: WebAuthn
  verification happens inside a LiveView process, which has no `conn`
  to set the session cookie with).
  """
  @spec build_passkey_login_exchange(User.t()) :: String.t()
  def build_passkey_login_exchange(%User{} = user) do
    {token, user_token} = UserToken.build_passkey_exchange_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Consumes a passkey login exchange token (single-use, ~2 minutes).
  """
  @spec login_user_by_passkey_exchange_token(String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def login_user_by_passkey_exchange_token(token) do
    with {:ok, query} <- UserToken.verify_passkey_exchange_token_query(token),
         {user, token_row} <- Repo.one(query) do
      Repo.delete!(token_row)
      {:ok, user}
    else
      _not_found -> {:error, :not_found}
    end
  end

  @doc """
  Gets the user with the given magic link token.
  """
  @spec get_user_by_magic_link_token(String.t()) :: User.t() | nil
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  The link is single-use: the token is deleted on success. First use also
  confirms the account and expires every other outstanding token.
  """
  @spec login_user_by_magic_link(String.t()) ::
          {:ok, {User.t(), [UserToken.t()]}} | {:error, :not_found}
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)
    query |> Repo.one() |> consume_login_token()
  end

  @doc """
  Logs the user in by short sign-in code (issue #177) — the
  cross-device variant of the magic link: single-use, same 15-minute
  lifetime, and additionally scoped to the email it was sent to since
  8 characters, unlike a 32-byte token, could be guessed if the search
  weren't narrowed and rate-limited (see `Kammer.RateLimit`).
  """
  @spec login_user_by_code(String.t(), String.t()) ::
          {:ok, {User.t(), [UserToken.t()]}} | {:error, :not_found}
  def login_user_by_code(email, code) do
    {:ok, query} = UserToken.verify_login_code_query(email, code)
    query |> Repo.one() |> consume_login_token()
  end

  # Shared consumption semantics for both email-proof credentials
  # (magic link and short code): single-use, and the first-ever use
  # confirms the account and expires every other outstanding token.
  defp consume_login_token({%User{confirmed_at: nil} = user, _token}) do
    with {:ok, {confirmed_user, _tokens}} = success <-
           user
           |> User.confirm_changeset()
           |> update_user_and_delete_all_tokens() do
      # SPEC §2: signing in upgrades any guest history on this email
      # into the account, automatically.
      Kammer.Guests.claim_history(confirmed_user)
      success
    end
  end

  defp consume_login_token({user, token}) do
    # Atomic single-use: two concurrent exchanges of the same token
    # race on this delete — the loser must get the same neutral
    # not-found as any spent token, not a StaleEntryError 500
    # (#197 review).
    case Repo.delete_all(from(t in UserToken, where: t.id == ^token.id)) do
      {1, _} ->
        Kammer.Guests.claim_history(user)
        {:ok, {user, []}}

      {0, _} ->
        {:error, :not_found}
    end
  end

  defp consume_login_token(nil), do: {:error, :not_found}

  @doc """
  Exchanges a single-use magic-link token for a long-lived API device
  token (ADR 0014): the API sibling of browser sign-in — same email
  proof, same revocability from the devices page. Consumes the magic
  link and confirms the account exactly like a web sign-in (including
  claiming any guest history).
  """
  @spec exchange_magic_link_for_device_token(String.t(), String.t() | nil) ::
          {:ok, String.t(), User.t()} | {:error, :not_found}
  def exchange_magic_link_for_device_token(magic_token, device_name) do
    with {:ok, {user, _expired_tokens}} <- login_user_by_magic_link(magic_token) do
      {:ok, create_device_token(user, device_name), user}
    end
  end

  @doc """
  Exchanges an emailed short sign-in code for a device token (issue
  #177): the cross-device sibling of
  `exchange_magic_link_for_device_token/2`. Rate limits are hit before
  verification and count every attempt — valid or not — so guessing
  burns the budget (`Kammer.RateLimit.hit_login_code_email/1`); a
  wrong code and an unknown email are indistinguishable to the caller.
  """
  @spec exchange_login_code_for_device_token(String.t(), String.t(), String.t() | nil,
          ip: :inet.ip_address() | String.t() | nil
        ) ::
          {:ok, String.t(), User.t()} | {:error, :not_found | :rate_limited}
  def exchange_login_code_for_device_token(email, code, device_name, opts \\ []) do
    with {:allow, _count} <- RateLimit.hit_login_code_email(email),
         {:allow, _count} <- RateLimit.hit_login_code_ip(Keyword.get(opts, :ip)),
         {:ok, {user, _expired_tokens}} <- login_user_by_code(email, code) do
      {:ok, create_device_token(user, device_name), user}
    else
      {:deny, _retry_after} -> {:error, :rate_limited}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Mints a long-lived API device token (ADR 0014) for a user who just
  proved their identity through a non-email path — passkey verify
  (issue #177). The email-proof paths go through the exchange
  functions above, which consume their single-use credential first.
  """
  @spec create_device_token(User.t(), String.t() | nil) :: String.t()
  def create_device_token(%User{} = user, device_name) do
    {encoded_token, user_token} = UserToken.build_device_token(user, device_name)
    Repo.insert!(user_token)
    encoded_token
  end

  @doc """
  The token row behind a valid API device token, or `nil` — lets the
  device listing mark which entry is the caller's own credential.
  """
  @spec get_device_token(String.t()) :: UserToken.t() | nil
  def get_device_token(token) do
    with {:ok, query} <- UserToken.verify_device_token_query(token),
         {_user, user_token} <- Repo.one(query) do
      user_token
    else
      _invalid -> nil
    end
  end

  @doc """
  The user behind a valid API device token, or `nil`.
  """
  @spec get_user_by_device_token(String.t()) :: User.t() | nil
  def get_user_by_device_token(token) do
    with {:ok, query} <- UserToken.verify_device_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _invalid -> nil
    end
  end

  @doc """
  Revokes the device token making the current request (API sign-out).
  """
  @spec revoke_device_token(String.t()) :: :ok
  def revoke_device_token(token) do
    with {:ok, query} <- UserToken.verify_device_token_query(token),
         {_user, user_token} <- Repo.one(query) do
      Repo.delete!(user_token)
      :ok
    else
      _invalid -> :ok
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  @spec deliver_user_update_email_instructions(User.t(), String.t(), (String.t() -> String.t())) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers magic-link login instructions to the given user, enforcing the
  per-email and per-IP rate limits (SPEC §2, §11).

  `client_ip` may be `nil` when unavailable (then only the email limit
  applies). With `code: true` (the API-initiated PWA flow, issue #177)
  the email also carries a short single-use sign-in code for typing
  into the app on another device — one email, one rate-limit hit, two
  credentials with the same lifetime.
  """
  @spec deliver_login_instructions(User.t(), (String.t() -> String.t()),
          ip: :inet.ip_address() | String.t() | nil,
          code: boolean()
        ) ::
          {:ok, Swoosh.Email.t()} | {:error, :rate_limited | term()}
  def deliver_login_instructions(%User{} = user, magic_link_url_fun, opts \\ [])
      when is_function(magic_link_url_fun, 1) do
    client_ip = Keyword.get(opts, :ip)

    with {:allow, _count} <- RateLimit.hit_magic_link_email(user.email),
         {:allow, _count} <- RateLimit.hit_magic_link_ip(client_ip) do
      {encoded_token, user_token} = UserToken.build_email_token(user, "login")
      Repo.insert!(user_token)

      code =
        if Keyword.get(opts, :code, false) do
          {code, code_token} = UserToken.build_login_code(user)
          Repo.insert!(code_token)
          code
        end

      UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token), code)
    else
      {:deny, _retry_after} -> {:error, :rate_limited}
    end
  end

  @doc """
  Deletes the signed token with the given context.
  """
  @spec delete_user_session_token(binary()) :: :ok
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(
          from(token in UserToken, where: token.id in ^Enum.map(tokens_to_expire, & &1.id))
        )

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
