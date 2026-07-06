defmodule Kammer.Storage.Local do
  @moduledoc """
  Local-disk storage adapter (the default, SPEC §1). Files live under the
  configured uploads path; keys are relative paths and are sanitized
  against traversal.
  """

  @behaviour Kammer.Storage

  @impl Kammer.Storage
  @spec put(Kammer.Storage.key(), Path.t()) :: :ok | {:error, term()}
  def put(key, source_path) do
    destination = absolute_path(key)
    File.mkdir_p!(Path.dirname(destination))

    case File.cp(source_path, destination) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Kammer.Storage
  @spec put_binary(Kammer.Storage.key(), binary()) :: :ok | {:error, term()}
  def put_binary(key, contents) do
    destination = absolute_path(key)
    File.mkdir_p!(Path.dirname(destination))
    File.write(destination, contents)
  end

  @impl Kammer.Storage
  @spec path_for(Kammer.Storage.key()) :: {:ok, Path.t()} | {:error, :not_found}
  def path_for(key) do
    path = absolute_path(key)
    if File.exists?(path), do: {:ok, path}, else: {:error, :not_found}
  end

  @impl Kammer.Storage
  @spec delete(Kammer.Storage.key()) :: :ok
  def delete(key) do
    key |> absolute_path() |> File.rm()
    :ok
  end

  defp absolute_path(key) do
    root = uploads_root()
    path = Path.expand(Path.join(root, key))

    unless String.starts_with?(path, Path.expand(root)) do
      raise ArgumentError, "storage key escapes the uploads root: #{inspect(key)}"
    end

    path
  end

  defp uploads_root do
    Application.get_env(:kammer, :uploads_path, Path.join(File.cwd!(), "priv/uploads"))
  end
end
