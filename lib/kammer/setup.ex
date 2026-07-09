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
  alias Kammer.Communities.InstanceSettings
  alias Kammer.Repo

  @setup_token_key {__MODULE__, :setup_token}

  # For pointing a boot-failure message at the env var that caused it.
  @setting_env_vars %{
    instance_name: "INSTANCE_NAME",
    default_locale: "DEFAULT_LOCALE",
    community_creation_policy: "COMMUNITY_CREATION_POLICY",
    storage_policy: "STORAGE_POLICY"
  }

  @doc """
  Whether first-run setup has completed. Once true, the wizard is locked
  forever (SPEC §13).
  """
  @spec completed?() :: boolean()
  def completed? do
    Communities.get_instance_settings().setup_completed_at != nil
  end

  @doc """
  Supervisor entry point: runs `initialize/0` synchronously during
  application start and starts no process. Synchronous on purpose
  (issue #98): an invalid env-provided setting raises, and that raise
  must fail the boot the way `MAILER_ADAPTER` typos do — not crash a
  background task that the supervisor shrugs off.
  """
  @spec start_boot() :: :ignore
  def start_boot do
    initialize()
    :ignore
  end

  @doc """
  Applies environment-provided setup values (env always wins) and, when
  setup is still pending, generates the setup token and prints it to the
  logs. Called at application boot. Raises on invalid env values —
  env config errors fail the boot rather than being silently dropped
  (issue #98).
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
          {:ok,
           %{
             operator: User.t(),
             invite_token: String.t(),
             community_slug: String.t(),
             group_slug: String.t(),
             magic_link_sent: boolean()
           }}
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
        # the live SMTP test (SPEC §13). Setup is already committed, so a
        # broken mailer must not crash the wizard: surface it instead.
        :persistent_term.erase(@setup_token_key)
        {:ok, Map.put(result, :magic_link_sent, deliver_magic_link(result, magic_link_url_fun))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver_magic_link(result, magic_link_url_fun) do
    case Accounts.deliver_login_instructions(result.operator, magic_link_url_fun) do
      {:ok, _email} -> true
      {:error, _reason} -> false
    end
  rescue
    error ->
      Logger.error("setup: magic-link delivery failed: #{Exception.message(error)}")
      false
  catch
    :exit, reason ->
      Logger.error("setup: magic-link delivery failed: #{inspect(reason)}")
      false
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
  # Invalid values raise — a typo'd env var must fail the boot the way
  # MAILER_ADAPTER/STORAGE_ADAPTER typos do, never be silently dropped
  # or persisted unvalidated (issue #98).
  defp apply_environment_settings do
    settings = Communities.get_instance_settings()

    attrs =
      %{
        instance_name: System.get_env("INSTANCE_NAME"),
        default_locale: System.get_env("DEFAULT_LOCALE"),
        community_creation_policy: parse_policy(System.get_env("COMMUNITY_CREATION_POLICY")),
        storage_policy: parse_storage_policy(System.get_env("STORAGE_POLICY"))
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    if attrs != %{} do
      apply_environment_changeset!(settings, attrs)
    end

    if operator_email = System.get_env("OPERATOR_EMAIL") do
      case ensure_operator(%{"email" => operator_email}) do
        {:ok, _operator} ->
          :ok

        {:error, reason} ->
          raise "environment variable OPERATOR_EMAIL could not be applied: #{inspect(reason)}"
      end
    end

    :ok
  end

  # The same changeset as the wizard/UI path (issue #98): env-derived
  # values get InstanceSettings.changeset/2's validations — a
  # DEFAULT_LOCALE typo must never be persisted and fed to Gettext.
  defp apply_environment_changeset!(settings, attrs) do
    changeset = InstanceSettings.changeset(settings, attrs)

    if changeset.valid? do
      Repo.update!(changeset)
    else
      raise "invalid environment-provided instance settings: " <>
              Enum.map_join(changeset.errors, "; ", fn {field, {message, _opts}} ->
                "#{Map.get(@setting_env_vars, field, to_string(field))} #{message}"
              end)
    end
  end

  defp parse_policy(nil), do: nil
  defp parse_policy("operators_only"), do: :operators_only
  defp parse_policy("any_user"), do: :any_user

  defp parse_policy(other) do
    raise "unsupported COMMUNITY_CREATION_POLICY #{inspect(other)} " <>
            "(expected \"operators_only\" or \"any_user\")"
  end

  defp parse_storage_policy(nil), do: nil
  defp parse_storage_policy("unmetered"), do: :unmetered
  defp parse_storage_policy("quota"), do: :quota

  defp parse_storage_policy(other) do
    raise "unsupported STORAGE_POLICY #{inspect(other)} (expected \"unmetered\" or \"quota\")"
  end

  defp generate_token do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
