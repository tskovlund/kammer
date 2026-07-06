defmodule Kammer.Backups do
  @moduledoc """
  Backups (SPEC §14): one function that produces a complete,
  restorable snapshot — a `pg_dump` custom-format archive of the
  database plus a tarball of the local uploads directory — and prunes
  old snapshots. Exposed as `mix kammer.backup` for cron and hand use,
  and as a scheduled Oban job when `BACKUP_DIR` is configured.

  Optional encryption pipes both artifacts through `age` when an
  `--encrypt-to RECIPIENT` (or `BACKUP_AGE_RECIPIENT`) is given —
  encryption is the operator's choice, never silent.

  Restore steps live in `docs/backups.md` — a backup nobody has
  restored is a wish, not a backup.
  """

  require Logger

  @type result() :: %{database: Path.t(), uploads: Path.t() | nil}

  @doc """
  Writes a snapshot into `target_dir` (created if missing). Returns
  the paths written. Options:

    * `:encrypt_to` — an age recipient; both artifacts become `.age`
    * `:keep` — prune to the newest N snapshots per artifact kind
      (default: keep everything)
    * `:timestamp` — override the snapshot timestamp (tests)
  """
  @spec run(Path.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(target_dir, opts \\ []) do
    File.mkdir_p!(target_dir)

    timestamp =
      Keyword.get_lazy(opts, :timestamp, fn ->
        DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
      end)

    with {:ok, database_path} <- dump_database(target_dir, timestamp, opts),
         {:ok, uploads_path} <- archive_uploads(target_dir, timestamp, opts) do
      prune(target_dir, Keyword.get(opts, :keep))
      {:ok, %{database: database_path, uploads: uploads_path}}
    end
  end

  # pg_dump custom format: compressed, restorable object-by-object with
  # pg_restore, and immune to quoting subtleties.
  defp dump_database(target_dir, timestamp, opts) do
    repo_config = Application.fetch_env!(:kammer, Kammer.Repo)
    path = Path.join(target_dir, "kammer-db-#{timestamp}.dump")

    args =
      [
        "--format=custom",
        "--file=#{path}",
        "--host=#{repo_config[:hostname] || "localhost"}",
        "--port=#{repo_config[:port] || 5432}",
        "--username=#{repo_config[:username]}",
        repo_config[:database]
      ]

    environment =
      case repo_config[:password] do
        nil -> []
        password -> [{"PGPASSWORD", password}]
      end

    case System.cmd("pg_dump", args, env: environment, stderr_to_stdout: true) do
      {_output, 0} ->
        encrypt(path, opts)

      {output, status} ->
        File.rm(path)
        {:error, {:pg_dump_failed, status, String.trim(output)}}
    end
  end

  # Local uploads only: with the S3 adapter the object store carries
  # its own durability story, so the tarball is skipped (and said so).
  defp archive_uploads(target_dir, timestamp, opts) do
    uploads_dir = Application.get_env(:kammer, :uploads_path)

    cond do
      Application.get_env(:kammer, :storage_adapter) != Kammer.Storage.Local ->
        Logger.info("backup: S3 storage adapter — skipping uploads tarball")
        {:ok, nil}

      is_nil(uploads_dir) or not File.dir?(uploads_dir) ->
        Logger.info("backup: no local uploads directory yet — skipping uploads tarball")
        {:ok, nil}

      true ->
        path = Path.join(target_dir, "kammer-uploads-#{timestamp}.tar.gz")

        case System.cmd(
               "tar",
               ["-czf", path, "-C", Path.dirname(uploads_dir), Path.basename(uploads_dir)],
               stderr_to_stdout: true
             ) do
          {_output, 0} ->
            encrypt(path, opts)

          {output, status} ->
            File.rm(path)
            {:error, {:tar_failed, status, String.trim(output)}}
        end
    end
  end

  defp encrypt(path, opts) do
    case Keyword.get(opts, :encrypt_to) do
      nil ->
        {:ok, path}

      recipient ->
        encrypted_path = path <> ".age"

        case System.cmd(
               "age",
               ["--encrypt", "--recipient", recipient, "--output", encrypted_path, path],
               stderr_to_stdout: true
             ) do
          {_output, 0} ->
            File.rm!(path)
            {:ok, encrypted_path}

          {output, status} ->
            File.rm(encrypted_path)
            {:error, {:age_failed, status, String.trim(output)}}
        end
    end
  end

  # Prune per artifact kind so a failed uploads tarball can never age
  # out working database dumps.
  defp prune(_target_dir, nil), do: :ok

  defp prune(target_dir, keep) when is_integer(keep) and keep > 0 do
    for prefix <- ["kammer-db-", "kammer-uploads-"] do
      target_dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort(:desc)
      |> Enum.drop(keep)
      |> Enum.each(fn stale -> File.rm!(Path.join(target_dir, stale)) end)
    end

    :ok
  end
end
