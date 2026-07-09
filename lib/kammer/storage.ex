defmodule Kammer.Storage do
  @moduledoc """
  Storage behaviour (SPEC §1): file bytes live behind two adapters —
  local disk (default) and S3-compatible. The adapter is chosen by
  configuration; all callers go through this module.
  """

  @type key() :: String.t()

  @doc "Writes the file at `source_path` under `key`."
  @callback put(key(), Path.t()) :: :ok | {:error, term()}

  @doc "Writes binary `contents` under `key`."
  @callback put_binary(key(), binary()) :: :ok | {:error, term()}

  @doc "Returns a local filesystem path for reading `key` (downloading first if remote)."
  @callback path_for(key()) :: {:ok, Path.t()} | {:error, term()}

  @doc "Deletes `key`. Missing keys are not an error."
  @callback delete(key()) :: :ok | {:error, term()}

  @spec put(key(), Path.t()) :: :ok | {:error, term()}
  def put(key, source_path), do: adapter().put(key, source_path)

  @spec put_binary(key(), binary()) :: :ok | {:error, term()}
  def put_binary(key, contents), do: adapter().put_binary(key, contents)

  @spec path_for(key()) :: {:ok, Path.t()} | {:error, term()}
  def path_for(key), do: adapter().path_for(key)

  @spec delete(key()) :: :ok | {:error, term()}
  def delete(key), do: adapter().delete(key)

  @doc "Generates a fresh storage key with the given file extension."
  @spec generate_key(String.t()) :: key()
  def generate_key(extension) do
    date_prefix = Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "/")
    "#{date_prefix}/#{Ecto.UUID.generate()}#{extension}"
  end

  @doc """
  The configured storage adapter module — unset config means local
  disk (SPEC §1's default). Callers branching on the adapter must ask
  here instead of reading the config key, so "unset" cannot mean
  different things at different call sites (issue #98: backups read
  the raw key without the default and mistook dev's unset config
  for S3).
  """
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:kammer, :storage_adapter, Kammer.Storage.Local)
  end
end
