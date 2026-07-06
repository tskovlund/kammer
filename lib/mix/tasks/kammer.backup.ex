defmodule Mix.Tasks.Kammer.Backup do
  @shortdoc "Writes a database dump + uploads tarball snapshot"

  @moduledoc """
  Produces a restorable snapshot (SPEC §14):

      mix kammer.backup /var/backups/kammer
      mix kammer.backup /var/backups/kammer --keep 14
      mix kammer.backup /var/backups/kammer --encrypt-to age1...

  Writes `kammer-db-<timestamp>.dump` (pg_dump custom format) and, for
  local storage, `kammer-uploads-<timestamp>.tar.gz`. `--keep N`
  prunes to the newest N snapshots per artifact. `--encrypt-to`
  requires the `age` binary and encrypts both artifacts.

  Restore steps: `docs/backups.md`. In production releases the same
  code runs via `Kammer.Release.backup/1` or the scheduled job
  (`BACKUP_DIR`).
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [keep: :integer, encrypt_to: :string])

    if invalid != [] do
      Mix.raise("unknown options: #{inspect(invalid)}")
    end

    target_dir =
      case positional do
        [dir] ->
          dir

        _other ->
          Mix.raise("usage: mix kammer.backup TARGET_DIR [--keep N] [--encrypt-to AGE_RECIPIENT]")
      end

    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:kammer)

    case Kammer.Backups.run(target_dir, opts) do
      {:ok, %{database: database, uploads: uploads}} ->
        Mix.shell().info("database: #{database}")
        if uploads, do: Mix.shell().info("uploads:  #{uploads}")

      {:error, reason} ->
        Mix.raise("backup failed: #{inspect(reason)}")
    end
  end
end
