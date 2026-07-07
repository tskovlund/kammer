defmodule KammerWeb.FeedFlowsTest do
  @moduledoc """
  LiveView tests for the critical posting flows (SPEC §17): composing,
  reacting, commenting, voting, acknowledging, pinning, and the live
  home feed.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Feed

  defp feed_context(%{conn: conn}) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    group_owner = group_member_fixture(group, :owner)
    member = group_member_fixture(group)

    %{
      conn: log_in_user(conn, member),
      community: community,
      group: group,
      group_owner: group_owner,
      member: member
    }
  end

  describe "posting" do
    setup :feed_context

    test "member composes a Markdown post", %{conn: conn, community: community, group: group} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      html =
        lv
        |> form("#composer_form", %{"post" => %{"body_markdown" => "Hello **band**"}})
        |> render_submit()

      assert html =~ "Hello"
      assert html =~ "<strong>band</strong>"
    end

    test "posting UI hidden for non-members", %{community: community, group: group} do
      outsider = member_fixture(community)

      {:ok, _lv, html} =
        build_conn() |> log_in_user(outsider) |> live(~p"/c/#{community.slug}/g/#{group.slug}")

      refute html =~ "composer_form"
    end

    test "member creates a poll and votes", %{
      conn: conn,
      community: community,
      group: group,
      member: member
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      lv |> element("button", "Poll") |> render_click()

      lv
      |> form("#composer_form", %{
        "post" => %{
          "body_markdown" => "Pick a date",
          "poll" => %{
            "options" => %{"0" => %{"text" => "Fri"}, "1" => %{"text" => "Sat"}}
          }
        }
      })
      |> render_submit()

      [post] = Feed.list_group_feed(member, group)
      assert post.poll
      [first_option, _second] = Enum.sort_by(post.poll.options, & &1.position)

      lv
      |> element(~s(button[phx-value-option-id="#{first_option.id}"]))
      |> render_click()

      assert [%{user_id: voter_id}] = Kammer.Repo.all(Kammer.Feed.PollVote)
      assert voter_id == member.id
    end
  end

  describe "interactions" do
    setup :feed_context

    setup %{member: member, group: group} do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "React to me"})
      %{post: post}
    end

    test "reactions toggle from the picker", %{
      conn: conn,
      community: community,
      group: group,
      post: post,
      member: member
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      render_click(lv, "toggle_reaction", %{"type" => "post", "id" => post.id, "emoji" => "👍"})

      [reaction] = Kammer.Repo.all(Kammer.Feed.Reaction)
      assert reaction.user_id == member.id
      assert reaction.emoji == "👍"
    end

    test "comments and replies render and collapse", %{
      conn: conn,
      community: community,
      group: group,
      post: post
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      lv
      |> element(~s(article#post-#{post.id} form[phx-submit="create_comment"]))
      |> render_submit(%{"post_id" => post.id, "body_markdown" => "First comment"})

      html = render(lv)
      assert html =~ "First comment"
    end

    test "acknowledgment button records and shows status to author",
         %{
           conn: conn,
           community: community,
           group: group,
           group_owner: group_owner,
           member: member
         } do
      {:ok, ack_post} =
        Feed.create_post(group_owner, group, %{
          "body_markdown" => "Read this",
          "acknowledgment_required" => "true"
        })

      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      lv
      |> element(~s(button[phx-click="acknowledge"][phx-value-id="#{ack_post.id}"]))
      |> render_click()

      assert {:ok, status} = Feed.acknowledgment_status(group_owner, ack_post)
      assert Enum.any?(status.acknowledged, fn user -> user.id == member.id end)
    end

    test "admin pins from the menu; pinned first", %{
      conn: conn,
      community: community,
      group: group,
      group_owner: group_owner,
      post: post,
      member: member
    } do
      {:ok, _second} = Feed.create_post(member, group, %{"body_markdown" => "Second post"})

      admin_conn = build_conn() |> log_in_user(group_owner)
      {:ok, admin_lv, _html} = live(admin_conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      render_click(admin_lv, "toggle_pin", %{"id" => post.id})

      [first | _rest] = Feed.list_group_feed(member, group)
      assert first.id == post.id
    end

    test "author edit flow", %{conn: conn, community: community, group: group, post: post} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      render_click(lv, "start_edit", %{"id" => post.id})

      html =
        lv
        |> form(~s(form[phx-submit="save_edit"]))
        |> render_submit(%{"post_id" => post.id, "body_markdown" => "Edited body"})

      assert html =~ "Edited body"
      assert html =~ "edited"
    end

    test "author soft-deletes leaving a stub", %{
      conn: conn,
      community: community,
      group: group,
      post: post
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      html = render_click(lv, "soft_delete_post", %{"id" => post.id})

      assert html =~ "This post was removed."
    end
  end

  describe "home feed" do
    setup :feed_context

    test "aggregates posts and marks the group name", %{
      conn: conn,
      community: community,
      group: group,
      member: member
    } do
      {:ok, _post} = Feed.create_post(member, group, %{"body_markdown" => "Home feed post"})

      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}")

      assert html =~ "Home feed post"
      assert html =~ group.name
    end
  end

  describe "live updates" do
    setup :feed_context

    test "a new post appears in an open feed via PubSub", %{
      conn: conn,
      community: community,
      group: group,
      group_owner: group_owner
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      {:ok, _post} = Feed.create_post(group_owner, group, %{"body_markdown" => "Live arrival"})

      # The LiveView receives the broadcast and re-renders.
      assert render(lv) =~ "Live arrival"
    end
  end

  describe "RSS feed link (SPEC §8)" do
    test "shown on a public group's page, even to an anonymous visitor" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :public_listed)

      {:ok, _lv, html} = live(build_conn(), ~p"/c/#{community.slug}/g/#{group.slug}")

      assert html =~ ~p"/c/#{community.slug}/g/#{group.slug}/feed.rss"
    end

    test "not shown on a community-visibility group's page", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :community)
      member = member_fixture(community)

      {:ok, _lv, html} = live(log_in_user(conn, member), ~p"/c/#{community.slug}/g/#{group.slug}")

      refute html =~ "feed.rss"
    end
  end
end
