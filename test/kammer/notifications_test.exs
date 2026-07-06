defmodule Kammer.NotificationsTest do
  use Kammer.DataCase, async: true
  use Oban.Testing, repo: Kammer.Repo

  import Kammer.CommunitiesFixtures
  import Swoosh.TestAssertions

  alias Kammer.Feed
  alias Kammer.Notifications
  alias Kammer.Workers.NotificationFanoutWorker

  defp notification_context do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    group_owner = group_member_fixture(group, :owner)
    author = group_member_fixture(group)
    reader = group_member_fixture(group)

    %{
      community: community,
      group: group,
      group_owner: group_owner,
      author: author,
      reader: reader
    }
  end

  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end

  defp collect_emails(collected \\ []) do
    receive do
      {:email, email} -> collect_emails([email | collected])
    after
      50 -> collected
    end
  end

  defp assert_any_email_to(address) do
    emails = collect_emails()

    assert Enum.any?(emails, fn email ->
             Enum.any?(email.to, fn {_name, recipient} -> recipient == address end)
           end),
           "no email delivered to #{address} (got #{inspect(Enum.map(emails, & &1.to))})"
  end

  describe "channels_for/2 — the §9 matrix" do
    test "muted gets nothing, ever" do
      for kind <- [:post, :mention, :reply, :acknowledgment_required, :event_created] do
        assert Notifications.channels_for(kind, :muted) == []
      end
    end

    test "mentions reach every unmuted level with push and email" do
      for level <- [:everything, :highlights, :mentions_only] do
        assert Notifications.channels_for(:mention, level) == [:in_app, :push, :email]
      end
    end

    test "ordinary posts are in-app only at highlights, everything at everything" do
      assert Notifications.channels_for(:post, :highlights) == [:in_app]
      assert Notifications.channels_for(:post, :everything) == [:in_app, :push, :email]
      assert Notifications.channels_for(:post, :mentions_only) == []
    end

    test "highlight-class kinds get all channels at highlights" do
      for kind <- [:reply, :acknowledgment_required, :event_created, :event_reminder] do
        assert Notifications.channels_for(kind, :highlights) == [:in_app, :push, :email]
        assert Notifications.channels_for(kind, :mentions_only) == []
      end
    end
  end

  describe "defaults and preferences" do
    test "broadcast groups default to everything (SPEC §9)" do
      {community, _owner} = community_with_owner_fixture()
      broadcast_group = group_fixture(community, posting_policy: :admins_only)
      normal_group = group_fixture(community)

      assert Notifications.default_level(broadcast_group) == :everything
      assert Notifications.default_level(normal_group) == :highlights
    end

    test "set_level overrides the default and upserts" do
      %{group: group, reader: reader} = notification_context()

      assert Notifications.effective_level(reader, group) == :highlights
      {:ok, _preference} = Notifications.set_level(reader, group, :muted)
      assert Notifications.effective_level(reader, group) == :muted
      {:ok, _preference} = Notifications.set_level(reader, group, :everything)
      assert Notifications.effective_level(reader, group) == :everything
    end
  end

  describe "post fan-out" do
    setup do
      notification_context()
    end

    test "ordinary post: in-app for members, none for the author, no email at highlights",
         %{group: group, author: author, reader: reader} do
      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Ordinary news"})
      drain_delivered_emails()

      assert :ok = perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => post.id})

      reader_notifications = Notifications.list_notifications(reader)
      assert [%{kind: :post}] = reader_notifications

      assert Notifications.list_notifications(author) == []
      refute_email_sent()
    end

    test "muted members get nothing", %{group: group, author: author, reader: reader} do
      {:ok, _preference} = Notifications.set_level(reader, group, :muted)
      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Into the void"})

      assert :ok = perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => post.id})
      assert Notifications.list_notifications(reader) == []
    end

    test "acknowledgment-required posts email at highlights",
         %{group: group, author: author, reader: reader} do
      {:ok, post} =
        Feed.create_post(author, group, %{
          "body_markdown" => "Sign this",
          "acknowledgment_required" => "true"
        })

      drain_delivered_emails()
      assert :ok = perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => post.id})

      assert [%{kind: :acknowledgment_required}] = Notifications.list_notifications(reader)
      assert_any_email_to(reader.email)
    end

    test "display-name mention escalates for the mentioned member only",
         %{group: group, author: author, reader: reader} do
      {:ok, _preference} = Notifications.set_level(reader, group, :mentions_only)

      {:ok, plain_post} = Feed.create_post(author, group, %{"body_markdown" => "no ping"})

      assert :ok =
               perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => plain_post.id})

      assert Notifications.list_notifications(reader) == []

      {:ok, mention_post} =
        Feed.create_post(author, group, %{"body_markdown" => "Hello @#{reader.display_name}!"})

      assert :ok =
               perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => mention_post.id})

      assert [%{kind: :mention}] = Notifications.list_notifications(reader)
    end

    test "@admins mentions the admins", %{
      group: group,
      author: author,
      group_owner: group_owner,
      reader: reader
    } do
      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Ping @admins please"})
      assert :ok = perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => post.id})

      assert [%{kind: :mention}] = Notifications.list_notifications(group_owner)
      assert [%{kind: :post}] = Notifications.list_notifications(reader)
    end

    test "pending posts do not fan out", %{community: community} do
      queue_group = group_fixture(community, approval_queue: true)
      queue_author = group_member_fixture(queue_group)
      queue_reader = group_member_fixture(queue_group)

      {:ok, pending_post} =
        Feed.create_post(queue_author, queue_group, %{"body_markdown" => "Wait"})

      assert :ok =
               perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => pending_post.id})

      assert Notifications.list_notifications(queue_reader) == []
    end
  end

  describe "comment fan-out" do
    setup do
      notification_context()
    end

    test "replies notify the post author and parent author only",
         %{group: group, author: author, reader: reader, group_owner: group_owner} do
      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "root"})
      {:ok, comment} = Feed.create_comment(reader, post, %{"body_markdown" => "a reply to you"})

      assert :ok =
               perform_job(NotificationFanoutWorker, %{"type" => "comment", "id" => comment.id})

      assert [%{kind: :reply}] = Notifications.list_notifications(author)
      assert Notifications.list_notifications(group_owner) == []
      assert Notifications.list_notifications(reader) == []
    end
  end

  describe "event fan-out" do
    test "event creation notifies members as a highlight" do
      %{group: group, author: author, reader: reader} = notification_context()

      {:ok, event} =
        Kammer.Events.create_event(author, group, %{
          "title" => "Fanout Fest",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
        })

      drain_delivered_emails()
      assert :ok = perform_job(NotificationFanoutWorker, %{"type" => "event", "id" => event.id})

      assert [%{kind: :event_created}] = Notifications.list_notifications(reader)
      assert_any_email_to(reader.email)
    end
  end

  describe "notification center" do
    test "unread counting and marking read" do
      %{group: group, author: author, reader: reader} = notification_context()

      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "one"})
      assert :ok = perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => post.id})

      assert Notifications.unread_count(reader) == 1

      [notification] = Notifications.list_notifications(reader)
      :ok = Notifications.mark_read(reader, notification.id)
      assert Notifications.unread_count(reader) == 0

      # Users can't mark someone else's notification.
      {:ok, second_post} = Feed.create_post(author, group, %{"body_markdown" => "two"})

      assert :ok =
               perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => second_post.id})

      [unread] = Enum.filter(Notifications.list_notifications(reader), &is_nil(&1.read_at))
      :ok = Notifications.mark_read(author, unread.id)
      assert Notifications.unread_count(reader) == 1

      :ok = Notifications.mark_all_read(reader)
      assert Notifications.unread_count(reader) == 0
    end
  end

  describe "push subscriptions" do
    test "register and idempotency" do
      %{reader: reader} = notification_context()

      params = %{
        "endpoint" => "https://push.example.org/send/abc",
        "keys" => %{"p256dh" => "key-material", "auth" => "auth-material"}
      }

      assert {:ok, _subscription} = Notifications.register_push_subscription(reader, params)
      assert {:ok, _duplicate} = Notifications.register_push_subscription(reader, params)

      assert Kammer.Repo.aggregate(Kammer.Notifications.PushSubscription, :count) == 1
    end

    test "push is disabled without VAPID configuration" do
      refute Notifications.push_enabled?()
      # send_push is a no-op without keys — must not raise.
      %{reader: reader} = notification_context()
      assert :ok = Notifications.send_push(reader, %{title: "x", body: "y", url: "z"})
    end
  end
end
