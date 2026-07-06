defmodule Kammer.Workers.PurgeDeletedContentWorker do
  @moduledoc """
  Daily Oban job purging the content of posts/comments soft-deleted more
  than 30 days ago (SPEC §5) and expired transient attachments (SPEC §5).
  """

  use Oban.Worker, queue: :scheduled, max_attempts: 3

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    Kammer.Feed.purge_old_deleted_content()
    Kammer.Files.purge_expired_transient_files()
    :ok
  end
end
