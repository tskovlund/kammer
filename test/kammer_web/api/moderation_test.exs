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

  alias Kammer.Assignments
  alias Kammer.Audit
  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Groups.Group
  alias Kammer.Moderation
  alias Kammer.Repo

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

  describe "filing reports on event and assignment comments (issue #262)" do
    setup :context

    test "a member reports an event comment", %{
      community: community,
      owner: owner,
      group: group,
      author: author
    } do
      member = group_member_fixture(group)

      {:ok, event} =
        Events.create_event(author, group, %{
          "title" => "Fest",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
        })

      {:ok, comment} = Events.create_comment(author, event, %{"body_markdown" => "Grov tone"})

      path =
        ~p"/api/v1/communities/#{community.slug}/events/#{event.id}/comments/#{comment.id}/report"

      body =
        member
        |> api_conn()
        |> post(path, %{reason: "Chikane"})
        |> tap(&assert_operation_response(&1, "events_report_comment"))
        |> json_response(201)

      assert body["data"] == %{"status" => "reported"}

      # Duplicate collapse itself is pinned once, on the post sibling —
      # all four intake endpoints share ReportIntake.respond/2; this test
      # earns its place by pinning the ROUTE (wiring + queue landing).
      open = Moderation.list_open_reports(owner, community)
      assert Enum.any?(open, &(&1.comment_id == comment.id))
    end

    test "a member reports an assignment comment", %{
      community: community,
      owner: owner,
      author: author
    } do
      # Assignments are off by default (ADR 0016) — a group with the
      # tool enabled hosts the reported discussion.
      group =
        community
        |> group_fixture()
        |> Group.features_changeset(%{"features" => ["feed", "assignments"]})
        |> Repo.update!()
        |> Map.put(:community, community)

      group_membership_fixture(group, author)
      member = group_member_fixture(group)

      {:ok, assignment} = Assignments.create_assignment(author, group, %{"title" => "Kaffe"})

      {:ok, comment} =
        Assignments.create_comment(author, assignment, %{"body_markdown" => "Grov tone"})

      member
      |> api_conn()
      |> post(
        ~p"/api/v1/communities/#{community.slug}/assignments/#{assignment.id}/comments/#{comment.id}/report",
        %{reason: "Chikane"}
      )
      |> tap(&assert_operation_response(&1, "assignments_report_comment"))
      |> json_response(201)

      open = Moderation.list_open_reports(owner, community)
      assert Enum.any?(open, &(&1.comment_id == comment.id))
    end

    test "a comment belonging to a different event 404s — resolution stays within the subject",
         %{community: community, group: group, author: author} do
      member = group_member_fixture(group)
      starts = DateTime.add(DateTime.utc_now(:second), 48, :hour)

      {:ok, event_a} =
        Events.create_event(author, group, %{"title" => "A", "starts_at" => starts})

      {:ok, event_b} =
        Events.create_event(author, group, %{"title" => "B", "starts_at" => starts})

      {:ok, b_comment} = Events.create_comment(author, event_b, %{"body_markdown" => "På B"})

      # A real, visible comment reached through the WRONG event's URL must
      # answer the same neutral 404 as a nonexistent one — the lookup is
      # scoped to the named subject's own comments, never resolved
      # globally by id (the invariant a future global-resolution refactor
      # would silently break).
      member
      |> api_conn()
      |> post(
        ~p"/api/v1/communities/#{community.slug}/events/#{event_a.id}/comments/#{b_comment.id}/report",
        %{reason: "?"}
      )
      |> json_response(404)

      member
      |> api_conn()
      |> post(
        ~p"/api/v1/communities/#{community.slug}/events/#{event_a.id}/comments/#{b_comment.id}/report",
        %{"reason" => 42}
      )
      |> json_response(400)
    end

    test "a comment belonging to a different assignment 404s the same way", %{
      community: community,
      author: author
    } do
      group =
        community
        |> group_fixture()
        |> Group.features_changeset(%{"features" => ["feed", "assignments"]})
        |> Repo.update!()
        |> Map.put(:community, community)

      group_membership_fixture(group, author)
      member = group_member_fixture(group)
      {:ok, assignment_a} = Assignments.create_assignment(author, group, %{"title" => "A"})
      {:ok, assignment_b} = Assignments.create_assignment(author, group, %{"title" => "B"})

      {:ok, b_comment} =
        Assignments.create_comment(author, assignment_b, %{"body_markdown" => "På B"})

      # Same scoped-resolution invariant as the event twin above — the
      # assignment controller has its own lookup, so it needs its own pin.
      member
      |> api_conn()
      |> post(
        ~p"/api/v1/communities/#{community.slug}/assignments/#{assignment_a.id}/comments/#{b_comment.id}/report",
        %{reason: "?"}
      )
      |> json_response(404)

      # And a missing/non-string reason 400s before any lookup, on both
      # new endpoints (the fallback clauses are one-per-controller).
      member
      |> api_conn()
      |> post(
        ~p"/api/v1/communities/#{community.slug}/assignments/#{assignment_a.id}/comments/#{b_comment.id}/report",
        %{}
      )
      |> json_response(400)
    end

    test "event-comment reports draw from the same per-reporter budget as post reports", %{
      community: community,
      group: group,
      author: author
    } do
      member = group_member_fixture(group)
      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Mål"})

      {:ok, event} =
        Events.create_event(author, group, %{
          "title" => "Fest",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
        })

      {:ok, comment} = Events.create_comment(author, event, %{"body_markdown" => "Grov"})

      # Spend the whole budget on POST reports — the limiter is keyed on
      # the reporter, not the subject kind, so the event-comment report
      # finds nothing left.
      for _attempt <- 1..20, do: Moderation.report_post(member, post, "spam")

      body =
        member
        |> api_conn()
        |> post(
          ~p"/api/v1/communities/#{community.slug}/events/#{event.id}/comments/#{comment.id}/report",
          %{reason: "En for meget"}
        )
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

    test "banning the same address twice answers 422 naming the email field", %{
      community: community,
      owner: owner,
      author: author
    } do
      owner
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/moderation/bans", %{user_id: author.id})
      |> json_response(201)

      # The repeat (two admins racing, or a stale roster) conflicts on
      # the (community, email) unique index. The 422 detail must land on
      # `email` — the field a client form can actually map to copy — not
      # Ecto's first-composite-field default (`community_id`).
      %{"error" => %{"code" => "invalid_params", "details" => details}} =
        owner
        |> api_conn()
        |> post(~p"/api/v1/communities/#{community.slug}/moderation/bans", %{user_id: author.id})
        |> json_response(422)

      assert details["email"]
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

  describe "instance-wide bans (issue #259)" do
    setup :context

    test "an oversized email is a 422 naming the field, not a database error" do
      operator = instance_operator_fixture()

      # The column is varchar(255); without the changeset cap this was a
      # raw Postgrex value-too-long error rendered as a 500.
      %{"error" => %{"code" => "invalid_params", "details" => details}} =
        operator
        |> api_conn()
        |> post(~p"/api/v1/instance/moderation/bans", %{
          email: String.duplicate("a", 250) <> "@example.org"
        })
        |> json_response(422)

      assert details["email"]
    end

    test "an operator bans an email, lists it, and lifts it", %{author: author} do
      operator = instance_operator_fixture()

      created =
        operator
        |> api_conn()
        |> post(~p"/api/v1/instance/moderation/bans", %{
          email: author.email,
          reason: "  Chikane  "
        })
        |> tap(&assert_operation_response(&1, "instance_ban"))
        |> json_response(201)

      assert created["data"]["email"] == author.email
      # Whitespace-padded reasons are trimmed, like the LiveView form.
      assert created["data"]["reason"] == "Chikane"
      assert created["data"]["banned_by"]["id"] == operator.id

      listed =
        operator
        |> api_conn()
        |> get(~p"/api/v1/instance/moderation/bans")
        |> tap(&assert_operation_response(&1, "instance_bans"))
        |> json_response(200)

      assert [%{"id" => ban_id}] = listed["data"]

      operator
      |> api_conn()
      |> delete(~p"/api/v1/instance/moderation/bans/#{ban_id}")
      |> tap(&assert_operation_response(&1, "instance_unban"))
      |> json_response(200)

      assert Moderation.list_instance_bans(operator) == []
    end

    test "banning the same address twice answers 422 naming the email field", %{author: author} do
      operator = instance_operator_fixture()
      path = ~p"/api/v1/instance/moderation/bans"

      operator |> api_conn() |> post(path, %{email: author.email}) |> json_response(201)

      # The repeat conflicts on the unique email index; the detail must
      # land on `email` — the field a client form maps to its own copy.
      %{"error" => %{"code" => "invalid_params", "details" => details}} =
        operator |> api_conn() |> post(path, %{email: author.email}) |> json_response(422)

      assert details["email"]
    end

    test "a non-operator gets 403 on list and create, and 404 lifting a real ban", %{
      author: author
    } do
      operator = instance_operator_fixture()
      {:ok, ban} = Moderation.ban_instance(operator, "ude@example.com", nil)

      author
      |> api_conn()
      |> get(~p"/api/v1/instance/moderation/bans")
      |> json_response(403)

      author
      |> api_conn()
      |> post(~p"/api/v1/instance/moderation/bans", %{email: "nogen@example.com"})
      |> json_response(403)

      # A specific ban row a non-operator may not lift stays hidden —
      # the same not-found a nonexistent id gets.
      author
      |> api_conn()
      |> delete(~p"/api/v1/instance/moderation/bans/#{ban.id}")
      |> json_response(404)

      assert Moderation.get_instance_ban(ban.id)
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

    test "cursor-paginates newest first (issue #340)", %{community: community, owner: owner} do
      for summary <- ["one", "two", "three"] do
        Audit.record(community, owner, "community.settings_updated", summary)
      end

      %{"data" => [first, second], "next_cursor" => cursor} =
        owner
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/audit-log?limit=2")
        |> json_response(200)

      assert cursor
      assert [first["summary"], second["summary"]] == ["three", "two"]

      %{"data" => [third], "next_cursor" => nil} =
        owner
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/audit-log?limit=2&after=#{cursor}")
        |> json_response(200)

      assert third["summary"] == "one"
    end
  end
end
