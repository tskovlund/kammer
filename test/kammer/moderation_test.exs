defmodule Kammer.ModerationTest do
  @moduledoc """
  Reports and bans (SPEC §11): who may file, who sees the queue,
  dismiss vs. remove, one-open-report spam control, and the ban
  choke-point — a banned email cannot rejoin through any invite.
  """

  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures

  alias Kammer.Audit
  alias Kammer.Communities
  alias Kammer.Feed
  alias Kammer.Feed.Post
  alias Kammer.Moderation
  alias Kammer.Moderation.Report
  alias Kammer.Repo

  defp reported_post_context(_context) do
    {community, owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :community)
    author = group_member_fixture(group)
    reporter = group_member_fixture(group)
    moderator = group_member_fixture(group, :admin)

    {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Grimt indhold"})

    %{
      community: community,
      owner: owner,
      group: group,
      author: author,
      reporter: reporter,
      moderator: moderator,
      post: post
    }
  end

  describe "filing reports" do
    setup :reported_post_context

    test "viewers may report; outsiders may not; one open report per subject", %{
      community: community,
      reporter: reporter,
      post: post
    } do
      assert {:ok, report} = Moderation.report_post(reporter, post, "Det her er spam")
      assert report.status == :open
      assert report.community_id == community.id

      assert {:error, %Ecto.Changeset{}} =
               Moderation.report_post(reporter, post, "Stadig spam")

      outsider = user_fixture()
      assert {:error, :unauthorized} = Moderation.report_post(outsider, post, "?")
    end

    test "comments are reportable too", %{group: group, reporter: reporter, post: post} do
      {:ok, comment} =
        Feed.create_comment(reporter, Feed.get_post!(group, post.id), %{
          "body_markdown" => "Grim kommentar"
        })

      other_member = group_member_fixture(group)
      assert {:ok, report} = Moderation.report_comment(other_member, comment, "Ubehøvlet")
      assert report.comment_id == comment.id
    end
  end

  describe "the queue" do
    setup :reported_post_context

    test "admins and group moderators see it; members don't; actions enforce the same", %{
      community: community,
      owner: owner,
      reporter: reporter,
      moderator: moderator,
      post: post
    } do
      {:ok, report} = Moderation.report_post(reporter, post, "Spam")

      assert [%Report{}] = Moderation.list_open_reports(owner, community)
      assert [%Report{}] = Moderation.list_open_reports(moderator, community)
      assert Moderation.list_open_reports(reporter, community) == []

      assert {:error, :unauthorized} = Moderation.dismiss_report(reporter, report)

      assert {:ok, dismissed} = Moderation.dismiss_report(moderator, report)
      assert dismissed.status == :dismissed
      assert Moderation.list_open_reports(owner, community) == []
    end

    test "resolving removes the content (and the report dies with it)", %{
      community: community,
      owner: owner,
      moderator: moderator,
      reporter: reporter,
      post: post
    } do
      {:ok, report} = Moderation.report_post(reporter, post, "Væk med det")

      assert {:ok, _resolved} = Moderation.resolve_report(moderator, report)
      assert Repo.get(Post, post.id) == nil
      assert Repo.get(Report, report.id) == nil
      assert Moderation.list_open_reports(moderator, community) == []

      assert [%{action: "content.removed", metadata: %{"report_id" => report_id}}] =
               Audit.list_events(owner, community)

      assert report_id == report.id
    end
  end

  describe "bans" do
    setup :reported_post_context

    test "banning removes memberships and blocks rejoin; lifting restores", %{
      community: community,
      owner: owner,
      author: author
    } do
      assert {:ok, ban} = Moderation.ban_member(owner, community, author, "Gentagen spam")

      assert Communities.get_membership(community, author) == nil
      assert Moderation.banned?(community, author.email)

      # The single choke-point: no invite path can re-add them.
      assert {:error, :banned} = Communities.add_member(community, author)

      assert [%{action: "member.banned"}] = Audit.list_events(owner, community)

      assert {:ok, _lifted} = Moderation.unban(owner, ban)
      assert {:ok, _membership} = Communities.add_member(community, author)

      assert [%{action: "member.unbanned"}, %{action: "member.banned"}] =
               Audit.list_events(owner, community)
    end

    test "only admins ban; nobody bans admins or themselves", %{
      community: community,
      owner: owner,
      author: author,
      reporter: reporter
    } do
      assert {:error, :unauthorized} = Moderation.ban_member(reporter, community, author, nil)
      assert {:error, :unauthorized} = Moderation.ban_member(owner, community, owner, nil)

      {:ok, _membership} =
        Communities.add_member(community, author)
        |> then(fn {:ok, membership} ->
          Communities.update_member_role(owner, community, membership, :admin)
        end)

      assert {:error, :unauthorized} = Moderation.ban_member(owner, community, author, nil)
    end
  end

  describe "instance bans" do
    setup :reported_post_context

    test "banning removes memberships everywhere and blocks rejoin anywhere; lifting restores",
         %{community: community, owner: owner, author: author} do
      operator = instance_operator_fixture()
      other_community = community_fixture()
      {:ok, _other_membership} = Communities.add_member(other_community, author)

      assert {:ok, ban} = Moderation.ban_instance(operator, author.email, "Chikane")

      assert Communities.get_membership(community, author) == nil
      assert Communities.get_membership(other_community, author) == nil
      assert Moderation.instance_banned?(author.email)

      # The choke-point catches instance bans ahead of the per-community list.
      assert {:error, :instance_banned} = Communities.add_member(community, author)

      # The affected community's own admins see it in their audit log —
      # there is no single global log an instance-wide action belongs to.
      assert [%{action: "member.banned"}] = Audit.list_events(owner, community)

      assert {:ok, _lifted} = Moderation.unban_instance(operator, ban)
      assert {:ok, _membership} = Communities.add_member(community, author)
    end

    test "can ban an email with no account yet — blocks the eventual signup", %{
      community: community
    } do
      operator = instance_operator_fixture()
      email = unique_user_email()

      assert {:ok, _ban} = Moderation.ban_instance(operator, email, nil)

      future_signup = user_fixture(%{email: email})
      assert {:error, :instance_banned} = Communities.add_member(community, future_signup)
    end

    test "only operators ban instance-wide; nobody bans themselves or another operator", %{
      author: author
    } do
      operator = instance_operator_fixture()
      other_operator = instance_operator_fixture()

      assert {:error, :unauthorized} = Moderation.ban_instance(author, other_operator.email, nil)
      assert {:error, :unauthorized} = Moderation.ban_instance(operator, operator.email, nil)

      assert {:error, :unauthorized} =
               Moderation.ban_instance(operator, other_operator.email, nil)
    end

    test "refuses to ban a community owner — no single community to ask for a transfer", %{
      community: community,
      owner: owner
    } do
      operator = instance_operator_fixture()

      assert {:error, :unauthorized} = Moderation.ban_instance(operator, owner.email, nil)

      refute Moderation.instance_banned?(owner.email)
      assert Communities.get_membership(community, owner)
    end

    test "list_instance_bans is operator-only", %{author: author} do
      operator = instance_operator_fixture()
      {:ok, _ban} = Moderation.ban_instance(operator, author.email, nil)

      assert [%Moderation.InstanceBan{}] = Moderation.list_instance_bans(operator)
      assert Moderation.list_instance_bans(author) == []
      assert Moderation.list_instance_bans(nil) == []
    end
  end
end
