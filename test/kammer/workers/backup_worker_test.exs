defmodule Kammer.Workers.BackupWorkerTest do
  @moduledoc """
  Worker-level coverage for the nightly backup tick (SPEC §14): the
  three branches `perform/1` itself is responsible for — unconfigured
  no-op, a configured run succeeding, and a configured run's error
  surfacing instead of vanishing. `Kammer.Backups.run/2` itself is
  covered in depth by `Kammer.BackupsTest`.
  """

  # Exercises real backup config / Repo config — keep synchronous.
  use Kammer.DataCase, async: false
  use Oban.Testing, repo: Kammer.Repo

  alias Kammer.Workers.BackupWorker

  setup do
    original_backup = Application.get_env(:kammer, :backup)

    on_exit(fn ->
      if original_backup do
        Application.put_env(:kammer, :backup, original_backup)
      else
        Application.delete_env(:kammer, :backup)
      end
    end)

    :ok
  end

  test "unconfigured is a documented no-op" do
    Application.delete_env(:kammer, :backup)
    assert :ok = perform_job(BackupWorker, %{})
  end

  test "configured writes a dump and prunes to :keep" do
    target_dir =
      Path.join(
        System.tmp_dir!(),
        "kammer-backup-worker-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(target_dir) end)

    Application.put_env(:kammer, :backup, dir: target_dir, keep: 3)

    assert :ok = perform_job(BackupWorker, %{})

    assert target_dir |> File.ls!() |> Enum.any?(&String.starts_with?(&1, "kammer-db-"))
  end

  test "a failing dump surfaces as an error, not a silent :ok" do
    target_dir =
      Path.join(
        System.tmp_dir!(),
        "kammer-backup-worker-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(target_dir) end)

    Application.put_env(:kammer, :backup, dir: target_dir)

    original_repo_config = Application.get_env(:kammer, Kammer.Repo)
    on_exit(fn -> Application.put_env(:kammer, Kammer.Repo, original_repo_config) end)

    Application.put_env(
      :kammer,
      Kammer.Repo,
      Keyword.put(
        original_repo_config,
        :database,
        "kammer_does_not_exist_#{System.unique_integer([:positive])}"
      )
    )

    assert {:error, _reason} = perform_job(BackupWorker, %{})
  end
end
