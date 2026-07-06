defmodule Kammer.Accounts do
  @moduledoc """
  Identity and authentication (SPEC §2).

  Kammer is passwordless: users register and sign in with single-use,
  short-lived magic links delivered by email, rate-limited per email and
  per IP. Sessions are long-lived and individually revocable from the
  devices page.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.{User, UserNotifier, UserToken}
  alias Kammer.RateLimit
  alias Kammer.Repo

  ## Database getters

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
  profile field (SPEC §4).
  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
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
  Updates display name, language, and timezone.
  """
  @spec update_user_settings(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_settings(%User{} = user, attrs) do
    user
    |> User.settings_changeset(attrs)
    |> Repo.update()
  end

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

  @doc """
  Lists the user's active sessions ("devices", SPEC §2) newest first.
  """
  @spec list_user_sessions(User.t()) :: [UserToken.t()]
  def list_user_sessions(%User{} = user) do
    Repo.all(
      from(token in UserToken,
        where: token.user_id == ^user.id and token.context == "session",
        order_by: [desc: token.inserted_at]
      )
    )
  end

  @doc """
  Revokes one of the user's sessions by token id — the devices page action.

  Scoped to the given user so one user can never revoke another's session.
  """
  @spec revoke_user_session(User.t(), Ecto.UUID.t()) :: :ok
  def revoke_user_session(%User{} = user, token_id) do
    Repo.delete_all(
      from(token in UserToken,
        where: token.id == ^token_id and token.user_id == ^user.id and token.context == "session"
      )
    )

    :ok
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

    case Repo.one(query) do
      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
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
  applies).
  """
  @spec deliver_login_instructions(User.t(), (String.t() -> String.t()),
          ip: :inet.ip_address() | String.t() | nil
        ) ::
          {:ok, Swoosh.Email.t()} | {:error, :rate_limited | term()}
  def deliver_login_instructions(%User{} = user, magic_link_url_fun, opts \\ [])
      when is_function(magic_link_url_fun, 1) do
    client_ip = Keyword.get(opts, :ip)

    with {:allow, _count} <- RateLimit.hit_magic_link_email(user.email),
         {:allow, _count} <- RateLimit.hit_magic_link_ip(client_ip) do
      {encoded_token, user_token} = UserToken.build_email_token(user, "login")
      Repo.insert!(user_token)
      UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
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
