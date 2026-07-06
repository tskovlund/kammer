defmodule Kammer.Workers.DigestWorker do
  @moduledoc """
  The digest tick (SPEC §16): every morning at 06:00 UTC, deliver to
  everyone due — daily users every day, weekly users on Mondays. One
  failing recipient never blocks the rest.
  """

  use Oban.Worker, queue: :mailers, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now(:second)

    for user <- Kammer.Digests.due_users(now) do
      try do
        Kammer.Digests.deliver_digest(user, now)
      rescue
        exception ->
          Logger.error("digest for #{user.id} failed: #{Exception.message(exception)}")
      end
    end

    :ok
  end
end
