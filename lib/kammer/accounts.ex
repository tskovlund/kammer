defmodule Kammer.Accounts do
  @moduledoc """
  Identity and authentication (SPEC §2).

  Kammer is passwordless: users register and sign in with single-use,
  short-lived magic links delivered by email, rate-limited per email and
  per IP. Sessions are long-lived and individually revocable from the
  devices page.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Kammer.Accounts.{User, UserNotifier, UserPasskey, UserToken}
  alias Kammer.Moderation
  alias Kammer.RateLimit
  alias Kammer.Repo
  alias Kammer.Validation

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
    # A malformed email (e.g. a NUL from a raw sign-in request body) can't
    # match a stored address anyway, so answer `nil` rather than let it
    # ride a `where email = ?` into Postgres and 500 (issue #334). This
    # also keeps the sign-in response neutral for garbage input, the same
    # as for any unknown address (SPEC §11).
    if Validation.email_format?(email), do: Repo.get_by(User, email: email)
  end

  @doc """
  Gets a single user, raising `Ecto.NoResultsError` if absent.
  """
  @spec get_user!(Ecto.UUID.t()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a single user by id, or `nil` — including for a malformed id, so
  a caller passing an untrusted path/body value gets `nil` rather than a
  crash (the API ban flow relies on this).
  """
  @spec get_user(term()) :: User.t() | nil
  def get_user(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(User, uuid)
      :error -> nil
    end
  end

  def get_user(_id), do: nil

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
        |> insert_unless_banned()

      {:deny, _retry_after} ->
        {:error, :rate_limited}
    end
  end

  # Full instance-ban lockout (#377): a banned address can't bootstrap a
  # fresh account. Reject it with the same "has already been taken" email
  # error a duplicate address gets — register already reveals whether an
  # address is registered, so folding the ban into that one envelope keeps
  # a banned address indistinguishable from a taken one rather than adding
  # a separate ban oracle. The join gate (Communities.add_member/3) stays
  # the enforcement of record; this only stops the account existing at all.
  #
  # Gate on the EMAIL field's own validity, not the whole changeset. Two
  # reasons: a malformed address (a NUL byte, no @) must not ride an
  # unguarded `where email = ?` into Postgres as a 500 (#334) — an email
  # error means the format check already caught it; and gating on the whole
  # changeset would REOPEN the oracle — `unsafe_validate_unique` emits "has
  # already been taken" for a registered address even when another field
  # (e.g. display_name) is invalid, so a banned address must fold into that
  # same error under the same conditions, or the two become distinguishable.
  defp insert_unless_banned(changeset) do
    email = Ecto.Changeset.get_field(changeset, :email)

    if is_binary(email) and not Keyword.has_key?(changeset.errors, :email) and
         Moderation.instance_banned?(email) do
      {:error, Ecto.Changeset.add_error(changeset, :email, "has already been taken")}
    else
      Repo.insert(changeset)
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
  def update_user_email(%User{id: user_id} = user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           # Scope the match to the caller: the context already embeds
           # this user's current (unique) email, but binding the query to
           # user_id too means no future write path that changes an email
           # outside this function can leave a token a re-registrant of the
           # freed address could consume (defense in depth, review of #258).
           %UserToken{sent_to: email, user_id: ^user_id} <- Repo.one(query),
           # Full instance-ban lockout (#377): refuse the change if either
           # the current OR the target address is banned — a ban must not be
           # sheddable by moving the account to a fresh address, and no
           # account may move ONTO a banned one. Re-read the current address
           # under the same FOR UPDATE lock the ban paths take (#170-172):
           # ban_instance locks this same user row, so a ban of the *current*
           # address serializes with the change. A ban landing on the *target*
           # (a fresh address with no row to lock) in the same instant isn't
           # serialized here, but that race is benign — the account would then
           # sit on a banned address and be locked out on its very next
           # request by `ApiAuth.ban_gate`.
           current_email when is_binary(current_email) <- lock_user_email(user),
           false <-
             Moderation.instance_banned?(current_email) or Moderation.instance_banned?(email),
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
         # already-gone rather than a StaleEntryError 500. Lock-order
         # invariant (ADR 0029): this single-statement delete acquires
         # the device row FIRST, then its cascade takes any pending
         # step-up token — `confirm_step_up/1` deliberately locks in
         # that same device→token order; a future edit that reads or
         # deletes step-up tokens BEFORE the device row here would
         # reopen the deadlock the #294 security review closed.
         {1, _deleted} <- Repo.delete_all(from(t in UserToken, where: t.id == ^token.id)) do
      {:ok, token}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc """
  Revokes every device credential — browser session and API device token
  alike (`@device_contexts`) — the user holds, in one statement. Used
  when an account is banned instance-wide (`Kammer.Moderation.ban_instance/3`),
  so the ban severs live access, not just community membership, the way
  account deletion and an email change already do. Follows the ADR 0029
  lock order: this delete takes the device rows first, its cascade any
  pending step-up tokens.
  """
  @spec revoke_all_user_devices(User.t()) :: :ok
  def revoke_all_user_devices(%User{} = user) do
    Repo.delete_all(
      from(token in UserToken,
        where: token.user_id == ^user.id and token.context in ^@device_contexts
      )
    )

    :ok
  end

  @doc """
  Deletes every passkey the user holds. Used when an account is banned
  instance-wide (`Kammer.Moderation.ban_instance/3`): a retained passkey
  is a standing credential that would let a banned account re-authenticate
  through the usernameless sign-in ceremony, so the full lockout (#377)
  must revoke it alongside the device tokens.
  """
  @spec revoke_all_user_passkeys(User.t()) :: :ok
  def revoke_all_user_passkeys(%User{} = user) do
    Repo.delete_all(from(passkey in UserPasskey, where: passkey.user_id == ^user.id))

    :ok
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
           verify_registration(attestation_object, client_data_json, challenge) do
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

  # Wax.register/3 returns {:error, _} for a crypto failure, but *raises*
  # (a bare CBOR map-match inside it) on an attestation that is valid
  # base64url + valid CBOR yet not the expected map shape — reachable with
  # a crafted attestation_object. Rescue so that too is a clean {:error, _}
  # rather than a 500, keeping this function true to its @spec and the
  # caller's neutral-failure contract.
  defp verify_registration(attestation_object, client_data_json, challenge) do
    Wax.register(attestation_object, client_data_json, challenge)
  rescue
    error ->
      # The caller collapses this to a neutral client error, but a raise
      # here can also mean a Wax upgrade regression or a misconfiguration,
      # not just crafted input — leave a server-side breadcrumb so that
      # doesn't hide behind "attacker garbage" on every registration.
      Logger.warning("passkey registration raised: #{Exception.message(error)}")
      {:error, :invalid_attestation}
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
    # Cast first (mirrors revoke_user_device/2): a malformed id matches
    # nothing, the same idempotent no-op as a well-formed id that isn't the
    # caller's — never a binary_id CastError.
    case Ecto.UUID.cast(passkey_id) do
      {:ok, uuid} ->
        Repo.delete_all(
          from(passkey in UserPasskey,
            where: passkey.id == ^uuid and passkey.user_id == ^user.id
          )
        )

      :error ->
        :noop
    end

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
           ]),
         user = get_user!(passkey.user_id),
         # Full instance-ban lockout (#377): the same backstop the magic-link
         # and code exchanges carry, so passkey is not the one sign-in path
         # that mints a session for a banned account. A ban revokes passkeys,
         # so this only fires for a credential that survived the ban in a
         # race — collapsing into the same neutral `:not_found` as an unknown
         # credential, no oracle.
         false <- Moderation.instance_banned?(user.email) do
      record_passkey_use(passkey, auth_data.sign_count)
      {:ok, user}
    else
      nil -> {:error, :not_found}
      true -> {:error, :not_found}
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
    # Same guard as `get_user_by_email/1`: a malformed email must not
    # reach the `where sent_to = ?` lookup (a NUL there is a Postgres 500,
    # issue #334). A garbage address gets the same neutral not-found as
    # any unknown one.
    if Validation.email_format?(email) do
      {:ok, query} = UserToken.verify_login_code_query(email, code)
      query |> Repo.one() |> consume_login_token()
    else
      {:error, :not_found}
    end
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
    with {:ok, {user, _expired_tokens}} <- login_user_by_magic_link(magic_token),
         # Full instance-ban lockout (#377): a banned account gets no new
         # session even holding a valid magic link. The link is still
         # consumed (single-use) above, and a banned account collapses into
         # the same `:not_found` an invalid or expired link gets — no oracle.
         false <- Moderation.instance_banned?(user.email) do
      {:ok, create_device_token(user, device_name), user}
    else
      _not_found_or_banned -> {:error, :not_found}
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
         {:ok, {user, _expired_tokens}} <- login_user_by_code(email, code),
         # Full instance-ban lockout (#377): a banned account, a wrong code,
         # and an unknown email are one neutral answer — no ban oracle.
         false <- Moderation.instance_banned?(user.email) do
      {:ok, create_device_token(user, device_name), user}
    else
      {:deny, _retry_after} -> {:error, :rate_limited}
      _not_found_or_banned -> {:error, :not_found}
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
  Deletes every API device token for the user except `keep_id` — used
  after an email change, which invalidates all api-device tokens at
  once (they're bound to the address via `sent_to`). Without this the
  dead rows linger in `list_user_devices`, so the Devices page would
  show signed-out phones as if still active. Session tokens are NOT
  touched: they aren't email-bound, so a browser session survives the
  change and stays a live, listable device.
  """
  @spec purge_stale_api_devices(User.t(), Ecto.UUID.t()) :: {non_neg_integer(), nil}
  def purge_stale_api_devices(%User{} = user, keep_id) do
    # Deletes device rows first; each cascade then takes that row's
    # pending step-up tokens — the device→token lock order every other
    # path keeps (see revoke_user_device/2 and ADR 0029).
    Repo.delete_all(
      from(token in UserToken,
        where:
          token.user_id == ^user.id and token.context == "api-device" and token.id != ^keep_id
      )
    )
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

  ## Step-up re-authentication (issue #294, ADR 0029): before a
  ## credential change (passkey enroll/remove, foreign-device revoke,
  ## email-change initiation) the calling api-device token must have
  ## recently re-asserted a root of trust — a registered passkey, or a
  ## fresh email round-trip. The state lives on the device-token row
  ## itself (`stepped_up_at`), so it is per credential, dies with the
  ## row, and can never be replayed onto another device.

  @doc """
  Marks the given api-device token row as stepped up now. The window
  it stays fresh is `Kammer.Config.step_up_validity_minutes/0`.

  Update-by-query, not `Repo.update!`: the passkey path calls this on
  an unlocked row, and a concurrent sign-out/revoke deleting it must
  read as `{:error, :not_found}` (the caller's neutral failure), never
  a `StaleEntryError` 500 — the same already-gone discipline the
  revoke path keeps (#197).
  """
  @spec step_up_device(UserToken.t()) :: {:ok, UserToken.t()} | {:error, :not_found}
  def step_up_device(%UserToken{context: "api-device", id: id} = device) do
    now = DateTime.utc_now(:second)

    case Repo.update_all(
           from(t in UserToken, where: t.id == ^id and t.context == "api-device"),
           set: [stepped_up_at: now]
         ) do
      {1, _} -> {:ok, %{device | stepped_up_at: now}}
      {0, _} -> {:error, :not_found}
    end
  end

  @doc """
  Whether the given device-token row's step-up is still fresh — within
  `Kammer.Config.step_up_validity_minutes/0` of `stepped_up_at`.
  Accepts `nil` (no valid caller row) for the plug's convenience.
  """
  @spec device_stepped_up?(UserToken.t() | nil) :: boolean()
  def device_stepped_up?(%UserToken{context: "api-device", stepped_up_at: %DateTime{} = at}) do
    threshold =
      DateTime.add(DateTime.utc_now(), -Kammer.Config.step_up_validity_minutes(), :minute)

    DateTime.after?(at, threshold)
  end

  def device_stepped_up?(_absent_or_never), do: false

  @doc """
  Emails the account's own address a single-use step-up confirmation
  link bound to `device` — the emailed root-of-trust proof for devices
  without a usable passkey. Shares the magic-link email budget
  (`Kammer.RateLimit.hit_magic_link_email/1` + the IP limiter): both
  are sign-in-class emails to the account address, so one throttle
  covers them.
  """
  @spec deliver_step_up_instructions(User.t(), UserToken.t(), (String.t() -> String.t()),
          ip: :inet.ip_address() | String.t() | nil
        ) :: {:ok, Swoosh.Email.t()} | {:error, :rate_limited | term()}
  def deliver_step_up_instructions(
        %User{} = user,
        %UserToken{context: "api-device"} = device,
        step_up_url_fun,
        opts \\ []
      )
      when is_function(step_up_url_fun, 1) do
    with {:allow, _count} <- RateLimit.hit_magic_link_email(user.email),
         {:allow, _count} <- RateLimit.hit_magic_link_ip(Keyword.get(opts, :ip)) do
      {encoded_token, user_token} = UserToken.build_step_up_token(user, device.id)
      Repo.insert!(user_token)
      UserNotifier.deliver_step_up_instructions(user, step_up_url_fun.(encoded_token))
    else
      {:deny, _retry_after} -> {:error, :rate_limited}
    end
  end

  @doc """
  Consumes a step-up confirmation token: deletes that one token row
  (atomic single-use, like `consume_login_token/1`) and sets
  `stepped_up_at` on the device-token row it targets — nothing else.
  Deliberately NOT `consume_login_token/1`: that confirms accounts and
  expires every other outstanding token, both wrong here (issue #294 —
  a step-up must never sign other devices out or mint anything).
  """
  @spec confirm_step_up(String.t()) :: {:ok, UserToken.t()} | {:error, :not_found}
  def confirm_step_up(token) do
    with {:ok, query} <- UserToken.verify_step_up_token_query(token),
         %UserToken{} = step_up_token <- Repo.one(query) do
      Repo.transact(fn ->
        # Lock the TARGET device row before touching the step-up token:
        # `revoke_user_device/2` deletes the device row and cascades to
        # this token, taking locks in that D→T order — acquiring D first
        # here keeps both paths ordered identically, so a concurrent
        # confirm-vs-revoke on the same device cannot deadlock (found by
        # the #294 security review). Two concurrent confirms then race
        # on the delete below; the loser reads as the same neutral
        # not-found as any spent token.
        with %UserToken{context: "api-device"} = device <-
               Repo.one(
                 from(t in UserToken,
                   where: t.id == ^step_up_token.target_token_id,
                   # Belt-and-braces: the target is fixed at mint to the
                   # requester's own device, but binding the owner here
                   # makes cross-user elevation impossible by
                   # construction against any future mint path.
                   where: t.user_id == ^step_up_token.user_id,
                   lock: "FOR UPDATE"
                 )
               ),
             {1, _} <- Repo.delete_all(from(t in UserToken, where: t.id == ^step_up_token.id)) do
          step_up_device(device)
        else
          # The target row vanished between verify and here (the FK
          # normally cascades a revoked device's pending links away).
          _gone_or_spent -> {:error, :not_found}
        end
      end)
    else
      _invalid -> {:error, :not_found}
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

      iex> deliver_user_update_email_instructions(user, current_email, &PublicLinks.confirm_url(conn, :email_change, &1))
      {:ok, %{to: ..., body: ...}}

  """
  @spec deliver_user_update_email_instructions(
          User.t(),
          String.t(),
          (String.t() -> String.t()),
          keyword()
        ) :: {:ok, Swoosh.Email.t()} | {:error, :rate_limited | term()}
  def deliver_user_update_email_instructions(
        %User{} = user,
        current_email,
        update_email_url_fun,
        opts \\ []
      )
      when is_function(update_email_url_fun, 1) do
    # Keyed on the acting user, not the target: the recipient is a
    # user-chosen new address, so this caps one account from turning the
    # change-email form into an arbitrary-recipient email relay (#97).
    # Checked before the insert so a refused request writes no token row.
    # The API path (`AccountController`) consumes the limit itself,
    # before its uniqueness check, and passes `check_rate_limit: false`
    # so it isn't charged twice; the web flow keeps the check here.
    limit_result =
      if Keyword.get(opts, :check_rate_limit, true),
        do: RateLimit.hit_email_change(user.id),
        else: {:allow, 0}

    case limit_result do
      {:allow, _count} ->
        {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

        Repo.insert!(user_token)
        UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))

      {:deny, _retry_after} ->
        {:error, :rate_limited}
    end
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
