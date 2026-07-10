defmodule KammerWeb.Api.ModerationTest do
  @moduledoc """
  The moderation surface over the API (issue #183): the report queue,
  resolve/dismiss, community bans, and the audit log. The contract that
  matters is authorization — every endpoint answers to a moderator and
  hides from everyone else — plus the no-oracle stance: a report or ban
  a non-moderator can't act on is 404, never a 403 that would confirm
  it exists.
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
