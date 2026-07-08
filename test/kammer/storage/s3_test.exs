defmodule Kammer.Storage.S3Test do
  @moduledoc """
  The S3-compatible storage adapter (SPEC §1): correct request
  construction and response handling for `put/2`, `put_binary/2`,
  `path_for/1`, and `delete/1`, exercised against a fake S3 endpoint
  (`Req.Test`) standing in for MinIO/Hetzner/AWS. No production code
  behavior changed — `opts` is a test-only seam for injecting
  `plug: {Req.Test, name}`, defaulted to `[]` everywhere else.
  """

  use ExUnit.Case, async: false

  alias Kammer.Storage.S3

  setup do
    previous_s3 = Application.get_env(:kammer, :s3)

    Application.put_env(:kammer, :s3,
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      bucket: "test-bucket",
      region: "us-east-1",
      endpoint: "http://localhost:9999"
    )

    on_exit(fn ->
      if previous_s3 do
        Application.put_env(:kammer, :s3, previous_s3)
      else
        Application.delete_env(:kammer, :s3)
      end
    end)

    on_exit(fn ->
      System.tmp_dir!() |> Path.join("kammer_s3_cache/s3-test") |> File.rm_rf()
    end)

    {:ok, bucket} = Agent.start_link(fn -> %{} end)
    Req.Test.stub(__MODULE__, fake_bucket(bucket))

    %{opts: [plug: {Req.Test, __MODULE__}]}
  end

  defp fake_bucket(bucket) do
    fn conn ->
      "/test-bucket/" <> key = conn.request_path

      case conn.method do
        "PUT" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(bucket, &Map.put(&1, key, body))
          Plug.Conn.send_resp(conn, 200, "")

        "GET" ->
          case Agent.get(bucket, &Map.get(&1, key)) do
            nil -> Plug.Conn.send_resp(conn, 404, "")
            body -> Plug.Conn.send_resp(conn, 200, body)
          end

        "DELETE" ->
          Agent.update(bucket, &Map.delete(&1, key))
          Plug.Conn.send_resp(conn, 204, "")
      end
    end
  end

  defp unique_key(name), do: "s3-test/#{System.unique_integer([:positive])}/#{name}"

  describe "put_binary/2 and path_for/1" do
    test "round-trips contents through the fake bucket", %{opts: opts} do
      key = unique_key("hello.txt")

      assert :ok = S3.put_binary(key, "hello world", opts)
      assert {:ok, path} = S3.path_for(key, opts)
      assert File.read!(path) == "hello world"
    end

    test "a second read comes from the local cache without another download", %{opts: opts} do
      key = unique_key("cached.txt")
      assert :ok = S3.put_binary(key, "cache me", opts)

      assert {:ok, path} = S3.path_for(key, opts)

      # Break the fake endpoint: a cache hit must not need it again.
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "should not be hit") end)

      assert {:ok, ^path} = S3.path_for(key, opts)
      assert File.read!(path) == "cache me"
    end

    test "path_for/1 reports :not_found for a key that was never written", %{opts: opts} do
      assert {:error, :not_found} = S3.path_for(unique_key("never.txt"), opts)
    end

    test "an unexpected status on upload surfaces as an error", %{opts: opts} do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert {:error, {:unexpected_status, 500}} =
               S3.put_binary(unique_key("fails.txt"), "contents", opts)
    end

    test "an unexpected status on download surfaces as an error", %{opts: opts} do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 403, "forbidden") end)

      assert {:error, {:unexpected_status, 403}} = S3.path_for(unique_key("fails.txt"), opts)
    end
  end

  describe "put/2" do
    test "copies a source file's contents into the bucket", %{opts: opts} do
      key = unique_key("copied.ex")

      assert :ok = S3.put(key, __ENV__.file, opts)
      assert {:ok, path} = S3.path_for(key, opts)
      assert File.read!(path) == File.read!(__ENV__.file)
    end
  end

  describe "delete/1" do
    test "removes a written key, from the local cache and the bucket", %{opts: opts} do
      key = unique_key("to-delete.txt")
      assert :ok = S3.put_binary(key, "gone soon", opts)
      assert {:ok, _path} = S3.path_for(key, opts)

      assert :ok = S3.delete(key, opts)

      assert {:error, :not_found} = S3.path_for(key, opts)
    end

    test "deleting an already-missing key is not an error (S3 404 is treated as success)", %{
      opts: opts
    } do
      assert :ok = S3.delete(unique_key("never-existed.txt"), opts)
    end

    test "an unexpected status surfaces as an error", %{opts: opts} do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert {:error, {:unexpected_status, 500}} = S3.delete(unique_key("fails.txt"), opts)
    end
  end
end
