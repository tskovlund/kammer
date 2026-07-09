defmodule KammerWeb.Api.NotificationsTest do
  @moduledoc """
  The notification center and Web Push registration over REST
  (issue #30): cursor-paginated reads, mark-read one and all, and the
  no-existence-oracle guarantee — another user's notification id is a
  404, indistinguishable from an id that never existed.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Feed
  alias Kammer.Notifications
  alias Kammer.Repo

  defp context(_tags) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    author = group_member_fixture(group)
    reader = group_member_fixture(group)
    %{community: community, group: group, author: author, reader: reader}
  end

  defp notify(author, group, body) do
    {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => body})
    :ok = Notifications.fanout_post(post)
    post
  end

  describe "GET /api/v1/notifications" do
    setup :context

    test "lists own notifications newest first with cursor pagination", %{
      group: group,
      author: author,
      reader: reader
    } do
      for body <- ["one", "two", "three"], do: notify(author, group, body)

      %{"data" => [first, second], "next_cursor" => cursor} =
        reader
        |> api_conn()
        |> get(~p"/api/v1/notifications?limit=2")
        |> tap(&assert_operation_response(&1, "notifications_index"))
        |> json_response(200)

      assert cursor

      assert %{
               "kind" => "post",
               "read" => false,
               "actor" => %{"type" => "user"},
               "community" => %{"slug" => _slug},
               "group" => %{"slug" => _group_slug},
               "post_id" => _post_id
             } = first

      %{"data" => [third], "next_cursor" => nil} =
        reader
        |> api_conn()
        |> get(~p"/api/v1/notifications?limit=2&after=#{cursor}")
        |> json_response(200)

      # Newest first: the pages walk back through "three", "two", "one".
      inserted =
        Enum.map([first, second, third], fn entry ->
          {:ok, at, _offset} = DateTime.from_iso8601(entry["inserted_at"])
          at
        end)

      assert inserted == Enum.sort(inserted, {:desc, DateTime})

      # The author triggered them all and received none.
      %{"data" => []} =
        author |> api_conn() |> get(~p"/api/v1/notifications") |> json_response(200)
    end

    test "a group-authored post's actor is the group, not the human (#167)", %{
      group: group,
      reader: reader
    } do
      group_owner = group_member_fixture(group, :owner)

      {:ok, post} =
        Feed.create_post(group_owner, group, %{
          "body_markdown" => "From the board",
          "author_type" => "group"
        })

      :ok = Notifications.fanout_post(post)

      %{"data" => [entry]} =
        reader |> api_conn() |> get(~p"/api/v1/notifications") |> json_response(200)

      assert entry["actor"] == %{
               "type" => "group",
               "id" => group.id,
               "display_name" => group.name
             }
    end
  end

  describe "PUT /api/v1/notifications/:id/read and read-all" do
    setup :context

    test "marks own notifications read; foreign and unknown ids are 404", %{
      group: group,
      author: author,
      reader: reader
    } do
      notify(author, group, "unread me")

      %{"data" => [%{"id" => notification_id, "read" => false}]} =
        reader |> api_conn() |> get(~p"/api/v1/notifications") |> json_response(200)

      assert %{"status" => "read"} =
               reader
               |> api_conn()
               |> put(~p"/api/v1/notifications/#{notification_id}/read")
               |> tap(&assert_operation_response(&1, "notifications_mark_read"))
               |> json_response(200)

      %{"data" => [%{"read" => true, "read_at" => read_at}]} =
        reader |> api_conn() |> get(~p"/api/v1/notifications") |> json_response(200)

      assert read_at

      # Someone else's id and a nonexistent id answer identically.
      assert %{"error" => %{"code" => "not_found"}} =
               author
               |> api_conn()
               |> put(~p"/api/v1/notifications/#{notification_id}/read")
               |> json_response(404)

      assert %{"error" => %{"code" => "not_found"}} =
               reader
               |> api_conn()
               |> put(~p"/api/v1/notifications/#{Ecto.UUID.generate()}/read")
               |> json_response(404)
    end

    test "read-all clears every unread notification, scoped to the caller", %{
      group: group,
      author: author,
      reader: reader
    } do
      notify(author, group, "one")
      notify(author, group, "two")

      assert Notifications.unread_count(reader) == 2

      assert %{"status" => "read"} =
               reader
               |> api_conn()
               |> put(~p"/api/v1/notifications/read-all")
               |> tap(&assert_operation_response(&1, "notifications_mark_all_read"))
               |> json_response(200)

      assert Notifications.unread_count(reader) == 0
    end
  end

  describe "push subscriptions" do
    setup :context

    test "register, re-register (upsert no-op), and delete by endpoint", %{reader: reader} do
      subscription = %{
        "endpoint" => "https://push.example.org/send/api-abc",
        "keys" => %{"p256dh" => "key-material", "auth" => "auth-material"}
      }

      assert %{"status" => "subscribed"} =
               reader
               |> api_conn()
               |> post(~p"/api/v1/push-subscriptions", subscription)
               |> tap(&assert_operation_response(&1, "push_subscriptions_create"))
               |> json_response(201)

      # Same endpoint again: the web flow's upsert semantics — still 201.
      assert %{"status" => "subscribed"} =
               reader
               |> api_conn()
               |> post(~p"/api/v1/push-subscriptions", subscription)
               |> json_response(201)

      assert Repo.aggregate(Kammer.Notifications.PushSubscription, :count) == 1

      assert %{"status" => "deleted"} =
               reader
               |> api_conn()
               |> delete(~p"/api/v1/push-subscriptions?endpoint=#{subscription["endpoint"]}")
               |> tap(&assert_operation_response(&1, "push_subscriptions_delete"))
               |> json_response(200)

      assert Repo.aggregate(Kammer.Notifications.PushSubscription, :count) == 0
    end

    test "malformed subscriptions and missing endpoints are refused", %{reader: reader} do
      assert %{"error" => %{"code" => "invalid_params"}} =
               reader
               |> api_conn()
               |> post(~p"/api/v1/push-subscriptions", %{"endpoint" => "https://x"})
               |> json_response(422)

      assert %{"error" => %{"code" => "bad_request"}} =
               reader
               |> api_conn()
               |> delete(~p"/api/v1/push-subscriptions")
               |> json_response(400)
    end

    test "deletion is scoped to the device owner", %{author: author, reader: reader} do
      subscription = %{
        "endpoint" => "https://push.example.org/send/api-def",
        "keys" => %{"p256dh" => "key-material", "auth" => "auth-material"}
      }

      assert reader
             |> api_conn()
             |> post(~p"/api/v1/push-subscriptions", subscription)
             |> json_response(201)

      # Another user deleting the same endpoint touches nothing (and
      # learns nothing — the response is the same either way).
      assert %{"status" => "deleted"} =
               author
               |> api_conn()
               |> delete(~p"/api/v1/push-subscriptions?endpoint=#{subscription["endpoint"]}")
               |> json_response(200)

      assert Repo.aggregate(Kammer.Notifications.PushSubscription, :count) == 1
    end
  end
end
