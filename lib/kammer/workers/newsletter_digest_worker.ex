defmodule Kammer.Workers.NewsletterDigestWorker do
  @moduledoc """
  The newsletter digest tick (SPEC §8): every morning, shortly after
  the member digest tick, deliver to every daily/weekly subscriber
  due. One failing recipient never blocks the rest — same shape as
  `Kammer.Workers.DigestWorker`, scoped to guest subscriptions instead
  of user memberships.
  """

  use Oban.Worker, queue: :mailers, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now(:second)

    for subscription <- Kammer.Newsletters.due_subscriptions(now) do
      try do
        Kammer.Newsletters.deliver_digest(subscription, now)
      rescue
        exception ->
          Logger.error(
            "newsletter digest for subscription #{subscription.id} failed: " <>
              Exception.message(exception)
          )
      end
    end

    :ok
  end
end
