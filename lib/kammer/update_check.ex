defmodule Kammer.UpdateCheck do
  @moduledoc """
  The admin update notice (HANDOFF §5.6): a periodic, low-frequency
  check against this project's GitHub releases so instance operators
  know when a newer Kammer exists. Privacy-respecting by design — one
  small request a day at most, no payload beyond the version fetch,
  and the operator can turn it off entirely with `DISABLE_UPDATE_CHECK`.

  The result is recorded on the singleton `InstanceSettings` row
  rather than fetched live on every page load, keeping the network
  call to exactly the cadence `Kammer.Workers.UpdateCheckWorker` runs
  at (daily), not once per request.
  """

  require Logger

  alias Kammer.Communities
  alias Kammer.Communities.InstanceSettings
  alias Kammer.Repo

  @releases_url "https://api.github.com/repos/tskovlund/kammer/releases/latest"

  @doc """
  Whether the operator has opted in (the default) or set
  `DISABLE_UPDATE_CHECK` to opt out.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :kammer
    |> Application.get_env(:update_check, enabled: true)
    |> Keyword.fetch!(:enabled)
  end

  @doc """
  Runs the check and records the result. A no-op — not an error — when
  disabled or when the fetch itself fails, since a missed check simply
  tries again on the next scheduled run.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    if enabled?() do
      case fetch_latest_release(opts) do
        {:ok, %{version: version, url: url}} -> record(version, url)
        {:error, reason} -> Logger.warning("update check failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc "The version this running instance is built from."
  @spec current_version() :: String.t()
  def current_version do
    Application.spec(:kammer, :vsn) |> to_string()
  end

  @doc """
  Whether the last recorded check found a release newer than the
  running version. `false` if no check has run yet, or the recorded
  version can't be compared.
  """
  @spec update_available?(InstanceSettings.t()) :: boolean()
  def update_available?(%InstanceSettings{latest_known_version: nil}), do: false

  def update_available?(%InstanceSettings{latest_known_version: latest}) do
    Version.compare(latest, current_version()) == :gt
  rescue
    Version.InvalidVersionError -> false
  end

  defp fetch_latest_release(opts) do
    request =
      Req.new([url: @releases_url, headers: [{"accept", "application/vnd.github+json"}]] ++ opts)

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: %{"tag_name" => tag, "html_url" => url}}} ->
        {:ok, %{version: normalize_tag(tag), url: url}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record(version, url) do
    Communities.get_instance_settings()
    |> Ecto.Changeset.change(
      latest_known_version: version,
      latest_known_release_url: url,
      update_checked_at: DateTime.utc_now(:second)
    )
    |> Repo.update!()

    :ok
  end

  defp normalize_tag("v" <> version), do: version
  defp normalize_tag(version), do: version
end
