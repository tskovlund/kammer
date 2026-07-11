defmodule KammerWeb.Api.ModerationTest do
  @moduledoc """
  The moderation surface over the API: intake (filing a report on a
  post or comment, issue #256) and the queue side (issue #183) — the
  report queue, resolve/dismiss, community bans, and the audit log.
  The contract that matters is authorization — every queue endpoint
  answers to a moderator and hides from everyone else — plus the
  no-oracle stance: a report or ban a non-moderator can't act on is
  404, never a 403 that would confirm it exists. (Intake's own
  no-oracle case — reporting an invisible post 404s — lives with the
  other post-write verbs in `FeedWritesTest`.)
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Feed
  alias Kammer.Moderation

  defp context(_tags) do
    {community, owner} = community_with_owner_fixture()
    group = group_fixture(community)
    author = group_member_fixture(group)
    reporter = group_member_fixture(group)
    {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Spam-agtigt"})
    {:ok, report} = Moderation.report_post(reporter, post, "Det her er spam")

    %{community: community, owner: owner, group: group, author: author, report: report}
  end

  defp report_path(community, group, post) do
    ~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/posts/#{post.id}/report"
  end

  defp report_path(community, group, post, comment) do
    ~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/posts/#{post.id}/comments/#{comment.id}/report"
  end

  describe "filing reports (issue #256)" do
    setup :context

    test "a member reports a post; a repeat answers the same and stays one open report", %{
      community: community,
      owner: owner,
      group: group,
      author: author
    } do
      member = group_member_fixture(group)
      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Mistænkeligt"})
      path = report_path(community, group, post)

      body =
        member
        |> api_conn()
        |> post(path, %{reason: "Ligner svindel"})
        |> tap(&assert_operation_response(&1, "posts_report"))
        |> json_response(201)

      assert body["data"] == %{"status" => "reported"}

      # The duplicate collapses into the same neutral answer…
      member |> api_conn() |> post(path, %{reason: "Stadig svindel"}) |> json_response(201)

      open = Moderation.list_open_reports(owner, community)
      assert Enum.count(open, &(&1.post_id == post.id)) == 1

      # …but a genuinely invalid reason is still refused.
      member |> api_conn() |> post(path, %{reason: ""}) |> json_response(422)
    end

    test "a member reports a comment", %{
      community: community,
      owner: owner,
      group: group,
      author: author
    } do
      member = group_member_fixture(group)
      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Vært"})
      {:ok, comment} = Feed.create_comment(author, post, %{"body_markdown" => "Grov tone"})

      member
      |> api_conn()
      |> post(report_path(community, group, post, comment), %{reason: "Chikane"})
      |> tap(&assert_operation_response(&1, "comments_report"))
      |> json_response(201)

      open = Moderation.list_open_reports(owner, community)
      assert Enum.any?(open, &(&1.comment_id == comment.id))
    end

    test "a missing or non-string reason is a 400, before any visibility work", %{
      community: community,
      group: group,
      author: author
    } do
      member = group_member_fixture(group)
      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Vært"})

      member
      |> api_conn()
      |> post(report_path(community, group, post), %{})
      |> json_response(400)

      member
      |> api_conn()
      |> post(report_path(community, group, post), %{reason: 42})
      |> json_response(400)
    end

    test "an exhausted report budget answers 429 at the endpoint", %{
      community: community,
      group: group,
      author: author
    } do
      member = group_member_fixture(group)
      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Mål"})

      # Spend the per-reporter budget through the context — every
      # attempt counts, duplicates included — then prove the endpoint
      # maps the refusal onto 429.
      for _attempt <- 1..20, do: Moderation.report_post(member, post, "spam")

      body =
        member
        |> api_conn()
        |> post(report_path(community, group, post), %{reason: "En for meget"})
        |> json_response(429)

      assert body["error"]["code"] == "rate_limited"
    end
  end

  describe "report queue" do
    setup :context

    test "an admin sees the queue; a plain member sees nothing", %{
      community: community,
      owner: owner,
      author: author,
      report: report
    } do
      body =
        owner
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/moderation/reports")
        |> tap(&assert_operation_response(&1, "moderation_reports"))
        |> json_response(200)

      assert [%{"id" => id, "subject" => %{"type" => "post"}}] = body["data"]
      assert id == report.id

      assert author
             |> api_conn()
             |> get(~p"/api/v1/communities/#{community.slug}/moderation/reports")
             |> json_response(200)
             |> Map.fetch!("data") == []
    end
  end

  describe "resolving and dismissing" do
    setup :context

    test "an admin dismisses a report; the content stays", %{
      community: community,
      owner: owner,
      report: report
    } do
      owner
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/moderation/reports/#{report.id}/dismiss")
      |> tap(&assert_operation_response(&1, "moderation_dismiss"))
      |> json_response(200)

      assert Moderation.get_report(report.id).status == :dismissed
    end

    test "an admin resolves a report by removing the content", %{
      community: community,
      owner: owner,
      report: report
    } do
      owner
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/moderation/reports/#{report.id}/resolve")
      |> tap(&assert_operation_response(&1, "moderation_resolve"))
      |> json_response(200)

      # Resolving cascades the report row away with its content.
      assert Moderation.get_report(report.id) == nil
    end

    test "a non-moderator gets 404, not 403 — the report is hidden", %{
      community: community,
      author: author,
      report: report
    } do
      author
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/moderation/reports/#{report.id}/resolve")
      |> json_response(404)

      assert Moderation.get_report(report.id).status == :open
    end
  end

  describe "bans" do
    setup :context

    test "an admin bans and lists; a member may not ban", %{
      community: community,
      owner: owner,
      author: author
    } do
      ban =
        owner
        |> api_conn()
        |> post(~p"/api/v1/communities/#{community.slug}/moderation/bans", %{user_id: author.id})
        |> tap(&assert_operation_response(&1, "moderation_ban"))
        |> json_response(201)

      assert ban["data"]["email"] == author.email

      listed =
        owner
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/moderation/bans")
        |> tap(&assert_operation_response(&1, "moderation_bans"))
        |> json_response(200)

      assert [%{"id" => ban_id, "email" => email}] = listed["data"]
      assert email == author.email

      owner
      |> api_conn()
      |> delete(~p"/api/v1/communities/#{community.slug}/moderation/bans/#{ban_id}")
      |> tap(&assert_operation_response(&1, "moderation_unban"))
      |> json_response(200)

      assert Moderation.list_bans(owner, community) == []

      other = group_member_fixture(group_fixture(community))

      author
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/moderation/bans", %{user_id: other.id})
      |> json_response(403)
    end

    test "a non-admin ban is refused 403 even for an unknown user id — no existence oracle",
         %{community: community, author: author} do
      # Authorization precedes the target lookup, so a missing id and a
      # real one both answer 403 — the 404-vs-403 difference can't reveal
      # whether a given user exists.
      author
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/moderation/bans", %{
        user_id: Ecto.UUID.generate()
      })
      |> json_response(403)
    end

    test "unbanning a ban that belongs to another community answers 404", %{
      community: community,
      owner: owner
    } do
      {other, other_owner} = community_with_owner_fixture()
      target = member_fixture(other)
      {:ok, foreign_ban} = Moderation.ban_member(other_owner, other, target, nil)

      owner
      |> api_conn()
      |> delete(~p"/api/v1/communities/#{community.slug}/moderation/bans/#{foreign_ban.id}")
      |> json_response(404)
    end
  end

  describe "audit log" do
    setup :context

    test "records admin actions for admins, hidden from members", %{
      community: community,
      owner: owner,
      author: author
    } do
      owner
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/moderation/bans", %{user_id: author.id})
      |> json_response(201)

      body =
        owner
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/audit-log")
        |> tap(&assert_operation_response(&1, "audit_log"))
        |> json_response(200)

      assert Enum.any?(body["data"], &(&1["action"] == "member.banned"))

      assert author
             |> api_conn()
             |> get(~p"/api/v1/communities/#{community.slug}/audit-log")
             |> json_response(200)
             |> Map.fetch!("data") == []
    end

    test "dismissing a report is recorded in the audit log", %{
      community: community,
      owner: owner,
      report: report
    } do
      owner
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/moderation/reports/#{report.id}/dismiss")
      |> json_response(200)

      body =
        owner
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/audit-log")
        |> json_response(200)

      assert Enum.any?(body["data"], &(&1["action"] == "report.dismissed"))
    end
  end
end
