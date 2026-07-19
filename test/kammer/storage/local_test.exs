defmodule Kammer.Storage.LocalTest do
  @moduledoc """
  The local-disk storage adapter (SPEC §1): correct read/write/delete
  round-tripping, and — the security-relevant part — that a storage key
  can never escape the configured uploads root (path traversal).
  """

  use ExUnit.Case, async: false

  alias Kammer.Storage.Local

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_uploads_path = Application.get_env(:kammer, :uploads_path)
    uploads_path = Path.join(tmp_dir, "uploads")
    Application.put_env(:kammer, :uploads_path, uploads_path)

    on_exit(fn ->
      if previous_uploads_path do
        Application.put_env(:kammer, :uploads_path, previous_uploads_path)
      else
        Application.delete_env(:kammer, :uploads_path)
      end
    end)

    %{uploads_path: uploads_path}
  end

  describe "path traversal guard" do
    @traversal_keys [
      "../secret",
      "../../etc/passwd",
      "2026/01/../../../secret",
      "./../secret"
    ]

    test "refuses every traversal style, exercised through put_binary/2" do
      for key <- @traversal_keys do
        assert_raise ArgumentError, ~r/escapes the uploads root/, fn ->
          Local.put_binary(key, "malicious contents")
        end
      end
    end

    test "the guard is wired into put/2, path_for/1, and delete/1 too" do
      assert_raise ArgumentError, fn -> Local.put("../secret", self_source_file()) end
      assert_raise ArgumentError, fn -> Local.path_for("../secret") end
      assert_raise ArgumentError, fn -> Local.delete("../secret") end
    end

    test "a traversal attempt never touches anything outside the uploads root", %{
      tmp_dir: tmp_dir,
      uploads_path: uploads_path
    } do
      canary = Path.join(tmp_dir, "canary")
      File.write!(canary, "untouched")

      assert_raise ArgumentError, fn ->
        Local.put_binary("../canary", "overwritten")
      end

      assert File.read!(canary) == "untouched"
      refute File.exists?(uploads_path)
    end
  end

  describe "well-behaved keys" do
    test "put_binary/2 then path_for/1 round-trips the contents", %{uploads_path: uploads_path} do
      assert :ok = Local.put_binary("2026/01/07/file.txt", "hello world")

      assert {:ok, path} = Local.path_for("2026/01/07/file.txt")
      assert path == Path.expand(Path.join(uploads_path, "2026/01/07/file.txt"))
      assert File.read!(path) == "hello world"
    end

    test "put/2 copies a source file into place" do
      source = self_source_file()

      assert :ok = Local.put("copied/key.ex", source)
      assert {:ok, path} = Local.path_for("copied/key.ex")
      assert File.read!(path) == File.read!(source)
    end

    test "path_for/1 reports :not_found for a key that was never written" do
      assert {:error, :not_found} = Local.path_for("never/written.txt")
    end

    test "delete/1 removes a written key and is a no-op for a missing one" do
      :ok = Local.put_binary("to-delete.txt", "gone soon")
      assert {:ok, _path} = Local.path_for("to-delete.txt")

      assert :ok = Local.delete("to-delete.txt")
      assert {:error, :not_found} = Local.path_for("to-delete.txt")

      # Deleting again (already gone) is not an error.
      assert :ok = Local.delete("to-delete.txt")
    end

    test "delete/1 surfaces a genuine failure instead of masking it as :ok", %{
      uploads_path: uploads_path
    } do
      # A directory can't be removed with File.rm, so it stands in for any
      # real unlink failure: delete/1 must report it, not swallow it — a
      # silent :ok here would let a blob leak with no operator signal.
      File.mkdir_p!(Path.join(uploads_path, "a-directory"))

      assert {:error, _reason} = Local.delete("a-directory")
    end
  end

  defp self_source_file, do: __ENV__.file
end
