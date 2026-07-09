defmodule Kammer.BackupsTest do
  @moduledoc """
  Backups (SPEC §14): a snapshot really lands on disk (pg_dump against
  the test database), pruning keeps the newest N per artifact kind,
  and failures surface instead of vanishing.
  """

  # pg_dump runs against the shared test database — not sandboxed, so
  # keep this file synchronous.
  use Kammer.DataCase, async: false

  alias Kammer.Backups

  setup do
    target_dir =
      Path.join(System.tmp_dir!(), "kammer-backup-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(target_dir) end)
    %{target_dir: target_dir}
  end

  test "writes a non-empty custom-format database dump", %{target_dir: target_dir} do
    assert {:ok, %{database: database_path}} =
             Backups.run(target_dir, timestamp: "20260706-000001")

    assert database_path == Path.join(target_dir, "kammer-db-20260706-000001.dump")
    assert File.exists?(database_path)
    # pg_dump custom format starts with the "PGDMP" magic bytes.
    assert <<"PGDMP", _rest::binary>> = File.read!(database_path) |> binary_part(0, 16)
  end

  test "pruning keeps the newest N dumps", %{target_dir: target_dir} do
    for suffix <- ["000001", "000002", "000003"] do
      assert {:ok, _result} = Backups.run(target_dir, timestamp: "20260706-#{suffix}", keep: 2)
    end

    dumps =
      target_dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "kammer-db-"))
      |> Enum.sort()

    assert dumps == ["kammer-db-20260706-000002.dump", "kammer-db-20260706-000003.dump"]
  end

  test "an unset storage adapter means local: the uploads tarball is written",
       %{target_dir: target_dir} do
    # :storage_adapter is only ever set in prod's runtime.exs, so this
    # is exactly the `mix kammer.backup`-outside-a-release case from
    # issue #98: unset must mean Local, as Kammer.Storage.adapter/0
    # already decides — not "S3, skip the tarball".
    uploads_dir =
      Path.join(System.tmp_dir!(), "kammer-uploads-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(uploads_dir)
    File.write!(Path.join(uploads_dir, "note.txt"), "back me up")

    previous_uploads_path = Application.get_env(:kammer, :uploads_path)
    Application.put_env(:kammer, :uploads_path, uploads_dir)

    on_exit(fn ->
      File.rm_rf!(uploads_dir)

      if previous_uploads_path do
        Application.put_env(:kammer, :uploads_path, previous_uploads_path)
      else
        Application.delete_env(:kammer, :uploads_path)
      end
    end)

    assert Application.get_env(:kammer, :storage_adapter) == nil

    assert {:ok, %{uploads: uploads_path}} =
             Backups.run(target_dir, timestamp: "20260706-000004")

    assert uploads_path == Path.join(target_dir, "kammer-uploads-20260706-000004.tar.gz")
    assert File.exists?(uploads_path)
  end

  test "a failing dump reports instead of pretending", %{target_dir: target_dir} do
    # Point pg_dump at a database that does not exist.
    original_config = Application.get_env(:kammer, Kammer.Repo)

    on_exit(fn -> Application.put_env(:kammer, Kammer.Repo, original_config) end)

    Application.put_env(
      :kammer,
      Kammer.Repo,
      Keyword.put(
        original_config,
        :database,
        "kammer_does_not_exist_#{System.unique_integer([:positive])}"
      )
    )

    assert {:error, {:pg_dump_failed, _status, output}} = Backups.run(target_dir)
    assert output =~ "does not exist"
  end
end
