defmodule KammerWeb.ModerationFlowsTest do
  @moduledoc """
  Moderation end to end (SPEC §11): report from the feed, act from the
  queue, ban from the members page.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Feed
  alias Kammer.Feed.Post
  alias Kammer.Moderation
  alias Kammer.Moderation.Report
  alias Kammer.Repo

  defp moderation_context(_context) do
    {community, owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :community)
    author = group_member_fixture(group)
    reporter = group_member_fixture(group)

    {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Tvivlsomt opslag"})

    %{
      community: community,
      owner: owner,
      group: group,
      author: author,
      reporter: reporter,
      post: post
    }
  end

  describe "the moderation journey" do
    setup :moderation_context

    test "report from the feed → remove from the queue", %{
      community: community,
      group: group,
      owner: owner,
      reporter: reporter,
      post: post
    } do
      reporter_conn = log_in_user(build_conn(), reporter)
      {:ok, feed_lv, _html} = live(reporter_conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      feed_lv |> element("#report-post-#{post.id}") |> render_click()

      feed_lv
      |> form("#report-form", %{reason: "Det her hører ikke hjemme her"})
      |> render_submit()

      [report] = Repo.all(Report)
      assert report.reason == "Det her hører ikke hjemme her"

      owner_conn = log_in_user(build_conn(), owner)
      {:ok, queue_lv, queue_html} = live(owner_conn, ~p"/c/#{community.slug}/moderation")
      assert queue_html =~ "Tvivlsomt opslag"

      queue_lv |> element("#resolve-report-#{report.id}") |> render_click()

      assert Repo.get(Post, post.id) == nil
      assert render(queue_lv) =~ "No open reports"
    end

    test "ban from the members page shows up on the moderation page", %{
      community: community,
      owner: owner,
      author: author
    } do
      owner_conn = log_in_user(build_conn(), owner)
      {:ok, members_lv, _html} = live(owner_conn, ~p"/c/#{community.slug}/members")

      membership = Kammer.Communities.get_membership(community, author)
      members_lv |> element("#ban-#{membership.id}") |> render_click()

      assert Moderation.banned?(community, author.email)

      {:ok, moderation_lv, moderation_html} =
        live(owner_conn, ~p"/c/#{community.slug}/moderation")

      assert moderation_html =~ author.email

      [ban] = Moderation.list_bans(owner, community)
      moderation_lv |> element("#unban-#{ban.id}") |> render_click()
      refute Moderation.banned?(community, author.email)
    end
  end
end
