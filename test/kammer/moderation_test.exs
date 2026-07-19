defmodule Kammer.ModerationTest do
  @moduledoc """
  Reports and bans (SPEC §11): who may file, who sees the queue,
  dismiss vs. remove, one-open-report spam control, and the ban
  choke-point — a banned email cannot rejoin through any invite.
  """

  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures

  alias Kammer.Accounts
  alias Kammer.Accounts.UserToken
  alias Kammer.Audit
  alias Kammer.Communities
  alias Kammer.Communities.CommunityMembership
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

    test "a refused attempt burns no report budget — authorization answers first", %{
      reporter: reporter,
      post: post
    } do
      # The limiter sits behind authorization on purpose (a refused caller
      # must not drain anything). Pinned by exhausting MORE than the hourly
      # budget in refused attempts on a foreign post, then reporting a
      # visible one: were the limiter consulted first, those refusals would
      # have spent the reporter's budget and this last report would answer
      # {:error, :rate_limited} instead of succeeding.
      {foreign_community, _owner} = community_with_owner_fixture()
      foreign_group = group_fixture(foreign_community, visibility: :community)
      foreign_author = group_member_fixture(foreign_group)

      {:ok, foreign_post} =
        Feed.create_post(foreign_author, foreign_group, %{"body_markdown" => "x"})

      for _attempt <- 1..25 do
        assert {:error, :unauthorized} = Moderation.report_post(reporter, foreign_post, "?")
      end

      assert {:ok, _report} = Moderation.report_post(reporter, post, "Det her er spam")
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

    test "a group moderator sees only their own group's reports, not another group's in the same community",
         %{community: community, moderator: moderator, reporter: reporter, post: post} do
      {:ok, report} = Moderation.report_post(reporter, post, "Spam")

      other_group = group_fixture(community, visibility: :community)
      other_author = group_member_fixture(other_group)
      other_moderator = group_member_fixture(other_group, :admin)

      {:ok, other_post} =
        Feed.create_post(other_author, other_group, %{"body_markdown" => "Også grimt"})

      {:ok, other_report} = Moderation.report_post(reporter, other_post, "Spam")

      assert [seen] = Moderation.list_open_reports(moderator, community)
      assert seen.id == report.id

      # Comment reports resolve their group through the preloaded parent
      # (#346 review) — scope them through the same filter.
      {:ok, other_comment} =
        Feed.create_comment(other_author, other_post, %{"body_markdown" => "og her"})

      {:ok, comment_report} = Moderation.report_comment(reporter, other_comment, "Spam")

      assert [seen] = Moderation.list_open_reports(moderator, community)
      assert seen.id == report.id

      other_seen_ids =
        Moderation.list_open_reports(other_moderator, community)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert other_seen_ids == Enum.sort([other_report.id, comment_report.id])
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

    test "lifting an already-lifted ban is a neutral not-found, not a 500", %{
      community: community,
      owner: owner,
      author: author
    } do
      {:ok, ban} = Moderation.ban_member(owner, community, author, nil)

      # A concurrent admin lifted the same ban first: the row is gone by
      # the time this delete runs. It must fold into the nonexistent-ban
      # path (:not_found), not raise a StaleEntryError (a controller 500).
      Repo.delete!(ban)

      assert {:error, :not_found} = Moderation.unban(owner, ban)
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

    test "the admin guard reads the target's current role, not the caller's snapshot", %{
      community: community,
      owner: owner,
      author: author
    } do
      # The struct in hand predates the promotion — the guard must
      # re-read the role inside the ban transaction (issue #129).
      stale_target = author
      membership = Communities.get_membership(community, author)
      {:ok, _admin} = Communities.update_member_role(owner, community, membership, :admin)

      assert {:error, :unauthorized} = Moderation.ban_member(owner, community, stale_target, nil)
      refute Moderation.banned?(community, author.email)
      assert Communities.get_membership(community, author)
    end

    test "the ban records the target's current email, not the caller's snapshot", %{
      community: community,
      owner: owner,
      author: author
    } do
      # The struct in hand predates an email change — the ban must
      # re-read the address from the row-locked user inside the
      # transaction, or the target could be re-invited immediately
      # under their new address (issue #171).
      stale_target = author
      new_email = unique_user_email()
      {:ok, _updated} = author |> Ecto.Changeset.change(email: new_email) |> Repo.update()

      assert {:ok, ban} = Moderation.ban_member(owner, community, stale_target, nil)
      assert ban.email == new_email
      assert Moderation.banned?(community, new_email)
      refute Moderation.banned?(community, stale_target.email)
    end

    test "a failed ban insert rolls the membership removal back — check and act are atomic", %{
      community: community,
      owner: owner,
      author: author
    } do
      {:ok, _existing_ban} = Moderation.ban_member(owner, community, author, nil)

      # Re-insert the membership directly (the add_member choke-point
      # would refuse a banned email) so a second ban attempt reaches
      # the duplicate-ban insert failure inside the transaction.
      {:ok, _membership} =
        Repo.insert(%CommunityMembership{
          community_id: community.id,
          user_id: author.id,
          role: :member
        })

      assert {:error, %Ecto.Changeset{}} = Moderation.ban_member(owner, community, author, nil)
      assert Communities.get_membership(community, author)
    end

    test "banning someone who is not a member still records the ban", %{
      community: community,
      owner: owner
    } do
      outsider = user_fixture()

      assert {:ok, _ban} = Moderation.ban_member(owner, community, outsider, nil)
      assert Moderation.banned?(community, outsider.email)
      assert {:error, :banned} = Communities.add_member(community, outsider)
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

    test "lifting an already-lifted instance ban is a neutral not-found, not a 500", %{
      author: author
    } do
      operator = instance_operator_fixture()
      {:ok, ban} = Moderation.ban_instance(operator, author.email, nil)

      # A concurrent operator lifted the same ban first: fold into the
      # nonexistent-ban 404 rather than raising on the stale delete.
      Repo.delete!(ban)

      assert {:error, :not_found} = Moderation.unban_instance(operator, ban)
    end

    test "can ban an email with no account yet — the eventual signup is refused (#377)" do
      operator = instance_operator_fixture()
      email = unique_user_email()

      # No user holds this address, so the purge (membership removal, token
      # and passkey revocation) is a no-op on the nil-target branch — but the
      # ban row still lands.
      assert {:ok, _ban} = Moderation.ban_instance(operator, email, nil)

      # Full lockout (#377) moved the block from the join choke-point to
      # registration: the pre-banned address can't sign up at all, so the
      # dormant account the join gate used to catch never forms.
      assert {:error, changeset} = Accounts.register_user(%{email: email, display_name: "Nope"})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "records an instance-level audit entry for the ban and the unban (#276)", %{
      author: author
    } do
      operator = instance_operator_fixture()

      {:ok, ban} = Moderation.ban_instance(operator, author.email, "Chikane")
      {:ok, _lifted} = Moderation.unban_instance(operator, ban)

      {entries, nil} = Audit.list_instance_events_page(operator, nil, 50)

      assert [%{action: "instance_ban.lifted"}, %{action: "instance_ban.created"}] = entries
      assert Enum.all?(entries, &(&1.community_id == nil))
      assert Enum.all?(entries, &(&1.summary =~ author.email))
    end

    test "a no-account ban still writes an instance audit entry — the gap #276 named" do
      operator = instance_operator_fixture()
      email = unique_user_email()

      # No community is affected (no account), so the per-community audit
      # loop is empty; the instance-level entry is the only record there is.
      assert {:ok, _ban} = Moderation.ban_instance(operator, email, nil)

      {[entry], nil} = Audit.list_instance_events_page(operator, nil, 50)
      assert entry.action == "instance_ban.created"
      assert entry.summary =~ email
    end

    test "revokes the banned account's device tokens, not just its memberships (#276)", %{
      author: author
    } do
      operator = instance_operator_fixture()

      _session = Accounts.generate_user_session_token(author)
      {_token, device} = UserToken.build_device_token(author, "phone")
      Repo.insert!(device)
      assert length(Accounts.list_user_devices(author)) == 2

      assert {:ok, _ban} = Moderation.ban_instance(operator, author.email, nil)

      # An instance ban locks the account out of every community, so its
      # live credentials die with its memberships — no session survives.
      assert Accounts.list_user_devices(author) == []
    end

    test "revokes the banned account's passkeys — a retained credential re-authenticates (#377)",
         %{author: author} do
      operator = instance_operator_fixture()

      Repo.insert!(%Kammer.Accounts.UserPasskey{
        user_id: author.id,
        credential_id: <<1, 2, 3>>,
        public_key_cose: <<0>>
      })

      assert length(Accounts.list_passkeys(author)) == 1

      assert {:ok, _ban} = Moderation.ban_instance(operator, author.email, nil)

      # A passkey is a standing credential the usernameless sign-in
      # ceremony accepts; leaving it would let a full-lockout ban be
      # walked straight back through the passkey path.
      assert Accounts.list_passkeys(author) == []
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

    test "rejects a control-char email with a changeset error, not a DB 500 (issue #334)" do
      operator = instance_operator_fixture()

      # A raw NUL used to reach the row-locked `where email = ?` lookup and
      # raise a Postgrex error (an unhandled 500). It's now caught before
      # the transaction as a 422-shaped changeset error.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Moderation.ban_instance(operator, "x" <> <<0>> <> "@y.z", nil)

      assert "must have the @ sign and no spaces" in errors_on(changeset).email
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

    test "refusing a community owner leaves their other memberships untouched", %{
      community: community,
      owner: owner
    } do
      # The ownership guard and the purge run in one transaction
      # (issue #129): a refusal must never leave a partial purge, even
      # of memberships that aren't the protected one.
      operator = instance_operator_fixture()
      other_community = community_fixture()
      {:ok, _membership} = Communities.add_member(other_community, owner)

      assert {:error, :unauthorized} = Moderation.ban_instance(operator, owner.email, nil)

      refute Moderation.instance_banned?(owner.email)
      assert Communities.get_membership(community, owner)
      assert Communities.get_membership(other_community, owner)
    end

    test "a failed instance-ban insert rolls the membership purge back", %{
      community: community,
      author: author
    } do
      operator = instance_operator_fixture()
      {:ok, _existing_ban} = Moderation.ban_instance(operator, author.email, nil)

      # Re-insert the membership directly (the add_member choke-point
      # would refuse a banned email) so a second ban attempt reaches
      # the duplicate-ban insert failure inside the transaction.
      {:ok, _membership} =
        Repo.insert(%CommunityMembership{
          community_id: community.id,
          user_id: author.id,
          role: :member
        })

      assert {:error, %Ecto.Changeset{}} = Moderation.ban_instance(operator, author.email, nil)
      assert Communities.get_membership(community, author)
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
