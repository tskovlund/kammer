defmodule Kammer.NotificationsTest do
  use Kammer.DataCase, async: true
  use Oban.Testing, repo: Kammer.Repo

  import Kammer.CommunitiesFixtures
  import Swoosh.TestAssertions

  alias Kammer.Assignments
  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Groups.Group
  alias Kammer.Notifications
  alias Kammer.Repo
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

    test "event comments notify the event creator (no post to resolve)",
         %{group: group, author: author, reader: reader} do
      {:ok, event} =
        Events.create_event(author, group, %{
          "title" => "Fanout Fest",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
        })

      {:ok, comment} = Events.create_comment(reader, event, %{"body_markdown" => "see you there"})

      assert :ok =
               perform_job(NotificationFanoutWorker, %{"type" => "comment", "id" => comment.id})

      assert [%{kind: :reply}] = Notifications.list_notifications(author)
      assert Notifications.list_notifications(reader) == []
    end

    test "assignment comments notify the assignment creator (no post to resolve)",
         %{group: group, author: author, reader: reader} do
      group =
        group
        |> Group.features_changeset(%{"features" => ["feed", "assignments"]})
        |> Repo.update!()

      {:ok, assignment} = Assignments.create_assignment(author, group, %{"title" => "Bring cups"})

      {:ok, comment} =
        Assignments.create_comment(reader, assignment, %{"body_markdown" => "on it"})

      assert :ok =
               perform_job(NotificationFanoutWorker, %{"type" => "comment", "id" => comment.id})

      assert [%{kind: :reply}] = Notifications.list_notifications(author)
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
    test "insert_notification!/1 broadcasts on the owner's topic" do
      %{group: group, reader: reader} = notification_context()

      # The event-reminder worker inserts through this helper; a bare
      # Repo.insert! would leave realtime subscribers blind.
      Notifications.subscribe(reader)

      notification =
        Notifications.insert_notification!(%{
          user_id: reader.id,
          community_id: group.community_id,
          group_id: group.id,
          kind: :event_reminder
        })

      notification_id = notification.id
      assert_receive {Notifications, {:notification_created, ^notification_id}}
    end

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
      assert {:error, :not_found} = Notifications.mark_read(author, unread.id)
      assert Notifications.unread_count(reader) == 1

      :ok = Notifications.mark_all_read(reader)
      assert Notifications.unread_count(reader) == 0
    end

    test "mark_read is idempotent for the owner and rejects garbage ids" do
      %{group: group, author: author, reader: reader} = notification_context()

      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "once"})
      assert :ok = perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => post.id})

      [notification] = Notifications.list_notifications(reader)
      assert :ok = Notifications.mark_read(reader, notification.id)
      assert :ok = Notifications.mark_read(reader, notification.id)

      assert {:error, :not_found} = Notifications.mark_read(reader, "not-a-uuid")
      assert {:error, :not_found} = Notifications.mark_read(reader, Ecto.UUID.generate())
    end

    test "list_notifications_page paginates newest first with an opaque-able cursor" do
      %{group: group, author: author, reader: reader} = notification_context()

      for body <- ["one", "two", "three"] do
        {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => body})
        assert :ok = perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => post.id})
      end

      {first_page, cursor} = Notifications.list_notifications_page(reader, nil, 2)
      assert length(first_page) == 2
      assert cursor

      {second_page, nil} = Notifications.list_notifications_page(reader, cursor, 2)
      assert length(second_page) == 1

      ids = Enum.map(first_page ++ second_page, & &1.id)
      assert ids == Enum.uniq(ids)

      # The pages cover everything the center shows, exactly once …
      all_ids = Notifications.list_notifications(reader) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort(all_ids)

      # … strictly descending by the cursor key across the page boundary.
      cursor_keys =
        Enum.map(first_page ++ second_page, fn notification ->
          {DateTime.to_iso8601(notification.inserted_at), notification.id}
        end)

      assert cursor_keys == Enum.sort(cursor_keys, :desc)

      # Scoped to the owner: the author has no notifications.
      assert {[], nil} = Notifications.list_notifications_page(author, nil, 10)
    end

    test "get_notification is owner-scoped and preloads what the serializer shapes" do
      %{group: group, author: author, reader: reader} = notification_context()

      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "hello"})
      assert :ok = perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => post.id})

      [%{id: notification_id}] = Notifications.list_notifications(reader)

      notification = Notifications.get_notification(reader, notification_id)
      assert notification.actor_user.id == author.id
      assert notification.community.id == group.community_id
      assert notification.group.id == group.id

      assert Notifications.get_notification(author, notification_id) == nil
      assert Notifications.get_notification(reader, "not-a-uuid") == nil
    end

    test "delivering an in-app notification broadcasts on the user's topic" do
      %{group: group, author: author, reader: reader} = notification_context()

      :ok = Notifications.subscribe(reader)

      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "ping"})
      assert :ok = perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => post.id})

      assert_receive {Kammer.Notifications, {:notification_created, notification_id}}
      assert %{user_id: user_id} = Repo.get!(Kammer.Notifications.Notification, notification_id)
      assert user_id == reader.id
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

    test "register rejects anything but the PushSubscription.toJSON() shape" do
      %{reader: reader} = notification_context()

      assert {:error, :invalid_subscription} =
               Notifications.register_push_subscription(reader, %{"endpoint" => "https://x"})

      assert {:error, :invalid_subscription} =
               Notifications.register_push_subscription(reader, %{
                 "endpoint" => "https://x",
                 "keys" => %{"p256dh" => "only-half"}
               })
    end

    test "delete_push_subscription removes only the owner's endpoint, idempotently" do
      %{author: author, reader: reader} = notification_context()

      params = %{
        "endpoint" => "https://push.example.org/send/def",
        "keys" => %{"p256dh" => "key-material", "auth" => "auth-material"}
      }

      assert {:ok, _subscription} = Notifications.register_push_subscription(reader, params)

      # Another user "deleting" the same endpoint touches nothing.
      assert :ok = Notifications.delete_push_subscription(author, params["endpoint"])
      assert Kammer.Repo.aggregate(Kammer.Notifications.PushSubscription, :count) == 1

      assert :ok = Notifications.delete_push_subscription(reader, params["endpoint"])
      assert Kammer.Repo.aggregate(Kammer.Notifications.PushSubscription, :count) == 0

      # Idempotent: a second delete is still :ok.
      assert :ok = Notifications.delete_push_subscription(reader, params["endpoint"])
    end

    test "push is disabled without VAPID configuration" do
      refute Notifications.push_enabled?()
      # send_push is a no-op without keys — must not raise.
      %{reader: reader} = notification_context()
      assert :ok = Notifications.send_push(reader, %{title: "x", body: "y", url: "z"})
    end
  end
end
