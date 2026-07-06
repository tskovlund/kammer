defmodule Kammer.Workers.PublishScheduledPostWorker do
  @moduledoc """
  Oban job enqueued for a scheduled post's publish time (SPEC §5):
  broadcasts the post into live feeds the moment it goes live (the post
  itself becomes visible by timestamp regardless — this job only makes
  it appear without a reload, and later fans out notifications).
  """

  use Oban.Worker, queue: :scheduled, max_attempts: 5

  alias Kammer.Feed.Post
  alias Kammer.Repo

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: %{"post_id" => post_id}}) do
    case Repo.get(Post, post_id) do
      nil ->
        :ok

      %Post{} = post ->
        Phoenix.PubSub.broadcast(
          Kammer.PubSub,
          Kammer.Feed.group_topic(post.group_id),
          {Kammer.Feed, {:post_created, post.id}}
        )

        :ok
    end
  end
end
