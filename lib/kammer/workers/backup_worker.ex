defmodule Kammer.Workers.BackupWorker do
  @moduledoc """
  Nightly scheduled backup (SPEC §14): runs `Kammer.Backups.run/2`
  into `BACKUP_DIR` when the operator configured one — otherwise the
  job is a documented no-op (backups are opt-in; silently writing to a
  surprise location would be worse). Retention and encryption follow
  `BACKUP_KEEP` and `BACKUP_AGE_RECIPIENT`.
  """

  use Oban.Worker, queue: :scheduled, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Application.get_env(:kammer, :backup) do
      nil ->
        :ok

      backup_config ->
        options =
          [
            keep: backup_config[:keep],
            encrypt_to: backup_config[:age_recipient]
          ]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        case Kammer.Backups.run(backup_config[:dir], options) do
          {:ok, result} ->
            Logger.info("backup: wrote #{result.database}")
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
