defmodule Kammer.Setup do
  @moduledoc """
  Hybrid first-run setup (SPEC §13, ADR 0010): env always wins — instance
  values present in the environment are applied at boot — and the wizard
  collects the remainder on first boot, protected by a setup token
  printed to the server logs. Setup locks permanently on completion.
  """

  require Logger

  alias Kammer.Accounts
  alias Kammer.Accounts.User
  alias Kammer.Communities
  alias Kammer.Repo

  @setup_token_key {__MODULE__, :setup_token}

  @doc """
  Whether first-run setup has completed. Once true, the wizard is locked
  forever (SPEC §13).
  """
  @spec completed?() :: boolean()
  def completed? do
    Communities.get_instance_settings().setup_completed_at != nil
  end

  @doc """
  Applies environment-provided setup values (env always wins) and, when
  setup is still pending, generates the setup token and prints it to the
  logs. Called at application boot.
  """
  @spec initialize() :: :ok
  def initialize do
    apply_environment_settings()

    unless completed?() do
      token = ensure_setup_token()

      Logger.info("""

      ================== Kammer first-run setup ==================
      Open /setup in your browser and enter this setup token:

          #{token}

      The wizard locks permanently once setup completes.
      ============================================================
      """)
    end

    :ok
  end

  @doc """
  Returns the current setup token, generating and storing one if none
  exists yet. Server-side only: the token reaches the operator through
  the server logs.
  """
  @spec ensure_setup_token() :: String.t()
  def ensure_setup_token do
    case :persistent_term.get(@setup_token_key, nil) do
      nil ->
        token = generate_token()
        :persistent_term.put(@setup_token_key, token)
        token

      token ->
        token
    end
  end

  @doc """
  Verifies a candidate setup token in constant time.
  """
  @spec valid_token?(String.t()) :: boolean()
  def valid_token?(candidate) when is_binary(candidate) do
    case :persistent_term.get(@setup_token_key, nil) do
      nil -> false
      token -> Plug.Crypto.secure_compare(candidate, token)
    end
  end

  def valid_token?(_candidate), do: false

  @doc """
  Completes the wizard in one transaction: operator account (magic link
  doubles as the live SMTP test), instance settings, first community,
  first group, invite link, optional demo data. Locks setup.

  Returns the created invite token and the operator user.
  """
  @spec complete(map(), (String.t() -> String.t())) ::
          {:ok, %{operator: User.t(), invite_token: String.t(), community_slug: String.t()}}
          | {:error, term()}
  def complete(attrs, magic_link_url_fun) do
    if completed?() do
      {:error, :already_completed}
    else
      run_completion(attrs, magic_link_url_fun)
    end
  end

  defp run_completion(attrs, magic_link_url_fun) do
    Repo.transact(fn ->
      with {:ok, operator} <- ensure_operator(attrs["operator"]),
           {:ok, _settings} <- apply_wizard_settings(operator, attrs["instance"] || %{}),
           {:ok, community} <- Communities.create_community(operator, attrs["community"] || %{}),
           {:ok, group} <-
             Kammer.Groups.create_group(operator, community, attrs["group"] || %{}),
           {:ok, invite} <- Kammer.Invitations.create_community_invite(operator, community),
           :ok <- maybe_create_demo_data(operator, attrs["demo_data"] == "true"),
           {:ok, _settings} <- lock_setup() do
        {:ok,
         %{
           operator: operator,
           invite_token: invite.token,
           community_slug: community.slug,
           group_slug: group.slug
         }}
      end
    end)
    |> case do
      {:ok, result} ->
        # Outside the transaction: deliver the operator's first magic link —
        # the live SMTP test (SPEC §13).
        Accounts.deliver_login_instructions(result.operator, magic_link_url_fun)
        :persistent_term.erase(@setup_token_key)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_operator(%{"email" => email} = operator_attrs) when is_binary(email) do
    case Accounts.get_user_by_email(email) do
      nil ->
        with {:ok, user} <-
               Accounts.register_user(%{
                 "email" => email,
                 "display_name" => operator_attrs["display_name"] || "Operator"
               }) do
          promote_operator(user)
        end

      %User{} = existing_user ->
        promote_operator(existing_user)
    end
  end

  defp ensure_operator(_missing), do: {:error, :operator_email_required}

  defp promote_operator(user) do
    user |> Ecto.Changeset.change(instance_operator: true) |> Repo.update()
  end

  defp apply_wizard_settings(operator, instance_attrs) do
    Communities.update_instance_settings(operator, instance_attrs)
  end

  defp lock_setup do
    Communities.get_instance_settings()
    |> Ecto.Changeset.change(setup_completed_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp maybe_create_demo_data(_operator, false), do: :ok

  defp maybe_create_demo_data(operator, true) do
    case Kammer.Setup.DemoData.create(operator) do
      {:ok, _community} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Env always wins (SPEC §13): apply instance-level values found in the
  # environment on every boot, so declarative deploys stay declarative.
  defp apply_environment_settings do
    settings = Communities.get_instance_settings()

    changes =
      [
        instance_name: System.get_env("INSTANCE_NAME"),
        default_locale: System.get_env("DEFAULT_LOCALE"),
        community_creation_policy: parse_policy(System.get_env("COMMUNITY_CREATION_POLICY")),
        storage_policy: parse_storage_policy(System.get_env("STORAGE_POLICY"))
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    if changes != [] do
      settings |> Ecto.Changeset.change(changes) |> Repo.update!()
    end

    if operator_email = System.get_env("OPERATOR_EMAIL") do
      ensure_operator(%{"email" => operator_email})
    end

    :ok
  end

  defp parse_policy("operators_only"), do: :operators_only
  defp parse_policy("any_user"), do: :any_user
  defp parse_policy(_other), do: nil

  defp parse_storage_policy("unmetered"), do: :unmetered
  defp parse_storage_policy("quota"), do: :quota
  defp parse_storage_policy(_other), do: nil

  defp generate_token do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
