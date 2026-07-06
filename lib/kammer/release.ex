defmodule Kammer.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :kammer

  @doc "Runs all pending Ecto migrations for every configured repo."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls the given repo back to the given migration version."
  @spec rollback(module(), integer()) :: {:ok, term(), term()}
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Writes a backup snapshot from a running release (SPEC §14) —
  `bin/kammer eval 'Kammer.Release.backup("/backups")'`. Options as in
  `Kammer.Backups.run/2`; restore steps in docs/backups.md.
  """
  @spec backup(Path.t(), keyword()) :: :ok
  def backup(target_dir, opts \\ []) do
    load_app()
    {:ok, _apps} = Application.ensure_all_started(@app)

    case Kammer.Backups.run(target_dir, opts) do
      {:ok, result} ->
        IO.puts("database: #{result.database}")
        if result.uploads, do: IO.puts("uploads:  #{result.uploads}")
        :ok

      {:error, reason} ->
        raise "backup failed: #{inspect(reason)}"
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
