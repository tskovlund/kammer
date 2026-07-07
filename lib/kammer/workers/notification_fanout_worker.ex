defmodule Kammer.Workers.NotificationFanoutWorker do
  @moduledoc """
  Asynchronous notification fan-out (SPEC §9) so posting stays instant on
  a mid-range phone (SPEC §20): computes recipients and delivers in-app,
  email, and push per the level matrix.
  """

  use Oban.Worker, queue: :mailers, max_attempts: 3

  alias Kammer.Newsletters
  alias Kammer.Notifications
  alias Kammer.Repo

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: %{"type" => "post", "id" => post_id}}) do
    case Repo.get(Kammer.Feed.Post, post_id) do
      nil ->
        :ok

      post ->
        if not post.pending_approval do
          Notifications.fanout_post(post)
          Newsletters.notify_subscribers(post)
        end

        :ok
    end
  end

  def perform(%Oban.Job{args: %{"type" => "comment", "id" => comment_id}}) do
    case Repo.get(Kammer.Feed.Comment, comment_id) do
      nil -> :ok
      comment -> Notifications.fanout_comment(comment)
    end
  end

  def perform(%Oban.Job{args: %{"type" => "event", "id" => event_id}}) do
    case Repo.get(Kammer.Events.Event, event_id) do
      nil -> :ok
      event -> Notifications.fanout_event(event)
    end
  end
end
