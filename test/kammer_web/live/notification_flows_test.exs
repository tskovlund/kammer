defmodule KammerWeb.NotificationFlowsTest do
  @moduledoc """
  LiveView tests for the notification center (SPEC §9).
  """

  use KammerWeb.ConnCase, async: true
  use Oban.Testing, repo: Kammer.Repo

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Feed
  alias Kammer.Notifications
  alias Kammer.Workers.NotificationFanoutWorker

  setup %{conn: conn} do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    author = group_member_fixture(group)
    reader = group_member_fixture(group)

    {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Notify me"})
    :ok = perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => post.id})

    %{
      conn: log_in_user(conn, reader),
      community: community,
      group: group,
      author: author,
      reader: reader
    }
  end

  test "center lists notifications and marks all read", %{
    conn: conn,
    community: community,
    author: author,
    reader: reader
  } do
    {:ok, lv, html} = live(conn, ~p"/c/#{community.slug}/notifications")

    assert html =~ author.display_name
    assert Notifications.unread_count(reader) == 1

    lv |> element("button", "Mark all read") |> render_click()
    assert Notifications.unread_count(reader) == 0
  end

  test "a group-authored post notifies as the group, not the human (#167)", %{
    conn: conn,
    community: community,
    group: group
  } do
    group_owner = group_member_fixture(group, :owner)

    {:ok, post} =
      Feed.create_post(group_owner, group, %{
        "body_markdown" => "From the board",
        "author_type" => "group"
      })

    :ok = perform_job(NotificationFanoutWorker, %{"type" => "post", "id" => post.id})

    {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/notifications")

    assert has_element?(lv, "li p", "#{group.name} posted")
    refute has_element?(lv, "li", group_owner.display_name)
  end
end
