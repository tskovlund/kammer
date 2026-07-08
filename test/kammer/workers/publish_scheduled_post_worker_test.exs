defmodule Kammer.Workers.PublishScheduledPostWorkerTest do
  @moduledoc """
  Worker-level coverage for the scheduled-post publish tick (SPEC §5):
  the live-broadcast branch, the pending-approval branch that skips
  notification fan-out, and the tolerate-a-vanished-post branch.
  """

  use Kammer.DataCase, async: true
  use Oban.Testing, repo: Kammer.Repo

  import Kammer.CommunitiesFixtures

  alias Kammer.Feed
  alias Kammer.Workers.NotificationFanoutWorker
  alias Kammer.Workers.PublishScheduledPostWorker

  setup do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)
    %{community: community, group: group, member: member}
  end

  defp future, do: DateTime.add(DateTime.utc_now(:second), 3600, :second)

  test "broadcasts the post and enqueues notification fan-out", %{group: group, member: member} do
    {:ok, post} =
      Feed.create_post(member, group, %{"body_markdown" => "Live now", "published_at" => future()})

    assert_enqueued(worker: PublishScheduledPostWorker, args: %{"post_id" => post.id})
    refute_enqueued(worker: NotificationFanoutWorker, args: %{"type" => "post", "id" => post.id})

    :ok = Phoenix.PubSub.subscribe(Kammer.PubSub, Feed.group_topic(group))

    assert :ok = perform_job(PublishScheduledPostWorker, %{"post_id" => post.id})

    assert_received {Kammer.Feed, {:post_created, post_id}}
    assert post_id == post.id

    assert_enqueued(worker: NotificationFanoutWorker, args: %{"type" => "post", "id" => post.id})
  end

  test "a post awaiting approval still broadcasts, but skips notification fan-out", %{
    community: community
  } do
    group = group_fixture(community, approval_queue: true)
    member = group_member_fixture(group)

    {:ok, post} =
      Feed.create_post(member, group, %{
        "body_markdown" => "Held for review",
        "published_at" => future()
      })

    assert post.pending_approval

    :ok = Phoenix.PubSub.subscribe(Kammer.PubSub, Feed.group_topic(group))

    assert :ok = perform_job(PublishScheduledPostWorker, %{"post_id" => post.id})

    assert_received {Kammer.Feed, {:post_created, _post_id}}
    refute_enqueued(worker: NotificationFanoutWorker, args: %{"type" => "post", "id" => post.id})
  end

  test "tolerates a post that no longer exists" do
    assert :ok = perform_job(PublishScheduledPostWorker, %{"post_id" => Ecto.UUID.generate()})
  end
end
