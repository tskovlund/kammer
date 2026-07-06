defmodule Kammer.Storage.S3 do
  @moduledoc """
  S3-compatible storage adapter (SPEC §1: MinIO / Hetzner Object Storage /
  any S3 API) built on `Req`'s native AWS SigV4 signing. Configuration
  comes from the `:kammer` application env (`:s3`, populated in
  runtime.exs from `S3_*` variables). Path-style addressing is used so
  MinIO works out of the box.

  Reads download to a per-node temporary cache so `send_file` and the
  image pipeline work identically to the local adapter.
  """

  @behaviour Kammer.Storage

  @impl Kammer.Storage
  @spec put(Kammer.Storage.key(), Path.t()) :: :ok | {:error, term()}
  def put(key, source_path) do
    put_binary(key, File.read!(source_path))
  end

  @impl Kammer.Storage
  @spec put_binary(Kammer.Storage.key(), binary()) :: :ok | {:error, term()}
  def put_binary(key, contents) do
    case Req.put(request(), url: object_url(key), body: contents) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Kammer.Storage
  @spec path_for(Kammer.Storage.key()) :: {:ok, Path.t()} | {:error, term()}
  def path_for(key) do
    cache_path = Path.join(cache_directory(), key)

    if File.exists?(cache_path) do
      {:ok, cache_path}
    else
      download(key, cache_path)
    end
  end

  defp download(key, cache_path) do
    case Req.get(request(), url: object_url(key)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        File.mkdir_p!(Path.dirname(cache_path))
        File.write!(cache_path, body)
        {:ok, cache_path}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Kammer.Storage
  @spec delete(Kammer.Storage.key()) :: :ok | {:error, term()}
  def delete(key) do
    cache_path = Path.join(cache_directory(), key)
    File.rm(cache_path)

    case Req.delete(request(), url: object_url(key)) do
      {:ok, %Req.Response{status: status}} when status in [200, 204, 404] -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request do
    configuration = configuration()

    Req.new(
      aws_sigv4: [
        access_key_id: Keyword.fetch!(configuration, :access_key_id),
        secret_access_key: Keyword.fetch!(configuration, :secret_access_key),
        service: "s3",
        region: Keyword.get(configuration, :region, "us-east-1")
      ]
    )
  end

  defp object_url(key) do
    configuration = configuration()
    bucket = Keyword.fetch!(configuration, :bucket)

    endpoint =
      Keyword.get(configuration, :endpoint) ||
        "https://s3.#{Keyword.get(configuration, :region, "us-east-1")}.amazonaws.com"

    "#{String.trim_trailing(endpoint, "/")}/#{bucket}/#{key}"
  end

  defp configuration do
    Application.fetch_env!(:kammer, :s3)
  end

  defp cache_directory do
    Path.join(System.tmp_dir!(), "kammer_s3_cache")
  end
end
