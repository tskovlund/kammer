defmodule Kammer.Workers.UpdateCheckWorker do
  @moduledoc """
  Daily admin update notice check (HANDOFF §5.6): a single small
  request to this project's GitHub releases API. A documented no-op
  when the operator set `DISABLE_UPDATE_CHECK` — see
  `Kammer.UpdateCheck.enabled?/0`.
  """

  use Oban.Worker, queue: :scheduled, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Kammer.UpdateCheck.run()
  end
end
