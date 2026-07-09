defmodule Kammer.CommunitiesTest do
  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures

  alias Kammer.Accounts.User
  alias Kammer.Audit
  alias Kammer.Communities
  alias Kammer.Moderation
  alias Kammer.Repo

  describe "instance settings" do
    test "get_instance_settings/0 creates the singleton on first access" do
      settings = Communities.get_instance_settings()
      assert settings.community_creation_policy == :operators_only
      assert settings.id == Communities.get_instance_settings().id
    end

    test "update_instance_settings/2 requires an instance operator" do
      operator = instance_operator_fixture()
      plain_user = user_fixture()

      assert {:error, :unauthorized} =
               Communities.update_instance_settings(plain_user, %{instance_name: "Nope"})

      assert {:ok, settings} =
               Communities.update_instance_settings(operator, %{instance_name: "Kammer Test"})

      assert settings.instance_name == "Kammer Test"
    end

    test "content_minimized_emails defaults off and is toggleable" do
      operator = instance_operator_fixture()

      refute Communities.get_instance_settings().content_minimized_emails

      assert {:ok, settings} =
               Communities.update_instance_settings(operator, %{content_minimized_emails: true})

      assert settings.content_minimized_emails
    end
  end

  describe "create_community/2" do
    test "operators can always create; creator becomes owner" do
      operator = instance_operator_fixture()

      assert {:ok, community} =
               Communities.create_community(operator, %{name: "TK", slug: unique_slug("tk")})

      membership = Communities.get_membership(community, operator)
      assert membership.role == :owner
    end

    test "plain users are refused under operators_only policy" do
      plain_user = user_fixture()

      assert {:error, :unauthorized} =
               Communities.create_community(plain_user, %{name: "TK", slug: unique_slug("tk")})
    end

    test "plain users can create under any_user policy" do
      allow_any_user_community_creation()
      plain_user = user_fixture()

      assert {:ok, _community} =
               Communities.create_community(plain_user, %{name: "TK", slug: unique_slug("tk")})
    end

    test "instance-banned creators are refused even when the policy allows them" do
      # An instance ban is an email-keyed rejoin block, so a banned
      # account's live session survives — it must not be able to create
      # (and own) a fresh community (issue #172).
      allow_any_user_community_creation()
      operator = instance_operator_fixture()
      banned_user = user_fixture()

      {:ok, _ban} = Moderation.ban_instance(operator, banned_user.email, nil)

      assert {:error, :unauthorized} =
               Communities.create_community(banned_user, %{name: "TK", slug: unique_slug("tk")})

      assert Communities.list_user_communities(banned_user) == []
    end

    test "rejects reserved and malformed slugs" do
      operator = instance_operator_fixture()

      assert {:error, changeset} =
               Communities.create_community(operator, %{name: "X", slug: "admin"})

      assert "is reserved" in errors_on(changeset).slug

      assert {:error, changeset} =
               Communities.create_community(operator, %{name: "X", slug: "Bad Slug!"})

      assert changeset.errors[:slug]
    end
  end

  describe "update_community/3" do
    test "admins may update, members may not" do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)

      assert {:error, :unauthorized} =
               Communities.update_community(member, community, %{name: "Renamed"})

      assert {:ok, updated} = Communities.update_community(owner, community, %{name: "Renamed"})
      assert updated.name == "Renamed"

      assert [%{action: "community.settings_updated"}] = Audit.list_events(owner, community)
    end
  end

  describe "membership management" do
    test "list_members/2 is restricted to community members" do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)
      outsider = user_fixture()

      assert {:error, :unauthorized} = Communities.list_members(outsider, community)
      assert {:ok, members} = Communities.list_members(member, community)
      assert length(members) == 2
      assert {:ok, _members} = Communities.list_members(owner, community)
    end

    test "update_member_role/4: admins manage roles, owner transitions need owner" do
      {community, owner} = community_with_owner_fixture()
      admin = member_fixture(community, :admin)
      member = member_fixture(community)
      member_membership = Communities.get_membership(community, member)

      assert {:ok, promoted} =
               Communities.update_member_role(admin, community, member_membership, :admin)

      assert promoted.role == :admin

      # An admin cannot grant Owner...
      assert {:error, :unauthorized} =
               Communities.update_member_role(admin, community, promoted, :owner)

      # ...but the owner can.
      assert {:ok, %{role: :owner}} =
               Communities.update_member_role(owner, community, promoted, :owner)

      assert [
               %{action: "member.role_changed", summary: owner_summary},
               %{action: "member.role_changed", summary: admin_summary}
             ] = Audit.list_events(owner, community)

      assert admin_summary =~ "to admin"
      assert owner_summary =~ "to owner"
    end

    test "remove_member/3: self-leave and admin removal; owners cannot be removed" do
      {community, owner} = community_with_owner_fixture()
      admin = member_fixture(community, :admin)
      member = member_fixture(community)
      other_member = member_fixture(community)

      # Members can leave — that's not an admin action, so it's not audited.
      membership = Communities.get_membership(community, member)
      assert {:ok, _deleted} = Communities.remove_member(member, community, membership)
      assert Communities.get_membership(community, member) == nil
      assert Audit.list_events(owner, community) == []

      # A plain member cannot remove someone else.
      other_membership = Communities.get_membership(community, other_member)
      third_member = member_fixture(community)

      assert {:error, :unauthorized} =
               Communities.remove_member(third_member, community, other_membership)

      # Admins can remove members — that IS an admin action, so it's audited.
      assert {:ok, _deleted} = Communities.remove_member(admin, community, other_membership)
      assert [%{action: "member.removed"}] = Audit.list_events(owner, community)

      # Owners cannot be removed, even by themselves.
      owner_membership = Communities.get_membership(community, owner)

      assert {:error, :owner_cannot_leave} =
               Communities.remove_member(owner, community, owner_membership)
    end

    test "add_member/3 checks bans against the current email, not the caller's snapshot" do
      # The ban re-checks run inside add_member's transaction against
      # the row-locked user (issue #170) — which also means they see
      # the current email, not a stale struct's snapshot.
      {community, owner} = community_with_owner_fixture()
      outsider = user_fixture()
      stale_struct = outsider
      new_email = unique_user_email()
      {:ok, _updated} = outsider |> Ecto.Changeset.change(email: new_email) |> Repo.update()

      # A community ban on the current address blocks the stale struct...
      {:ok, ban} = Moderation.ban_member(owner, community, Repo.get!(User, outsider.id), nil)
      assert {:error, :banned} = Communities.add_member(community, stale_struct)
      assert Communities.get_membership(community, outsider) == nil

      # ...and so does an instance ban on the current address.
      {:ok, _lifted} = Moderation.unban(owner, ban)
      operator = instance_operator_fixture()
      {:ok, _ban} = Moderation.ban_instance(operator, new_email, nil)
      assert {:error, :instance_banned} = Communities.add_member(community, stale_struct)
      assert Communities.get_membership(community, outsider) == nil
    end

    test "removing a community member also removes their group memberships" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      member = group_member_fixture(group)

      membership = Communities.get_membership(community, member)
      assert {:ok, _deleted} = Communities.remove_member(member, community, membership)
      assert Kammer.Groups.get_membership(group, member) == nil
    end
  end

  describe "cross-instance bookmarks" do
    test "full lifecycle, scoped to the owner" do
      user = user_fixture()
      other_user = user_fixture()

      assert {:ok, bookmark} =
               Communities.create_instance_bookmark(user, %{
                 name: "Band server",
                 url: "https://kammer.example.org"
               })

      assert [%{name: "Band server"}] = Communities.list_instance_bookmarks(user)
      assert [] = Communities.list_instance_bookmarks(other_user)

      # Deleting someone else's bookmark is a silent no-op.
      assert :ok = Communities.delete_instance_bookmark(other_user, bookmark.id)
      assert [_bookmark] = Communities.list_instance_bookmarks(user)

      assert :ok = Communities.delete_instance_bookmark(user, bookmark.id)
      assert [] = Communities.list_instance_bookmarks(user)
    end

    test "rejects non-http URLs" do
      user = user_fixture()

      assert {:error, changeset} =
               Communities.create_instance_bookmark(user, %{
                 name: "Bad",
                 url: "javascript:alert(1)"
               })

      assert changeset.errors[:url]
    end
  end
end
