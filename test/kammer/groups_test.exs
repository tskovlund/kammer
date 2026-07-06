defmodule Kammer.GroupsTest do
  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures

  alias Kammer.Groups

  describe "create_group/3" do
    test "community members create groups and become owner" do
      {community, _owner} = community_with_owner_fixture()
      member = member_fixture(community)

      assert {:ok, group} =
               Groups.create_group(member, community, %{
                 "name" => "Brass Section",
                 "slug" => unique_slug("brass")
               })

      assert Groups.get_membership(group, member).role == :owner
    end

    test "outsiders cannot create groups" do
      {community, _owner} = community_with_owner_fixture()
      outsider = user_fixture()

      assert {:error, :unauthorized} =
               Groups.create_group(outsider, community, %{
                 "name" => "X",
                 "slug" => unique_slug("x")
               })
    end

    test "sealed can be set at creation" do
      {community, _owner} = community_with_owner_fixture()
      member = member_fixture(community)

      assert {:ok, group} =
               Groups.create_group(member, community, %{
                 "name" => "Sealed Circle",
                 "slug" => unique_slug("sealed"),
                 "sealed" => "true",
                 "visibility" => "private"
               })

      assert group.sealed
    end
  end

  describe "update_group/3 and the sealed invariant" do
    test "group admins update settings; sealed is never cast on update" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, sealed: true, visibility: :private)
      group_admin = group_member_fixture(group, :admin)

      assert {:ok, updated} =
               Groups.update_group(group_admin, group, %{
                 "name" => "Renamed",
                 "slug" => group.slug,
                 "sealed" => "false"
               })

      assert updated.sealed, "sealed flag must be irreversible"
    end

    test "community admins cannot manage sealed groups" do
      {community, owner} = community_with_owner_fixture()
      group = group_fixture(community, sealed: true, visibility: :private)

      assert {:error, :unauthorized} =
               Groups.update_group(owner, group, %{"name" => "Taken over", "slug" => group.slug})
    end

    test "community admins can manage unsealed groups they are not members of" do
      {community, owner} = community_with_owner_fixture()
      group = group_fixture(community)

      assert {:ok, _updated} =
               Groups.update_group(owner, group, %{"name" => "Managed", "slug" => group.slug})
    end
  end

  describe "archive and delete" do
    test "archive blocks posting-related actions but keeps the group viewable" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      group_owner = group_member_fixture(group, :owner)

      assert {:ok, archived} = Groups.archive_group(group_owner, group)
      assert Kammer.Groups.Group.archived?(archived)

      assert {:ok, unarchived} = Groups.unarchive_group(group_owner, archived)
      refute Kammer.Groups.Group.archived?(unarchived)
    end

    test "community admin can delete a sealed group but a plain member cannot" do
      {community, owner} = community_with_owner_fixture()
      group = group_fixture(community, sealed: true, visibility: :private)
      plain_member = group_member_fixture(group, :member)

      assert {:error, :unauthorized} = Groups.delete_group(plain_member, group)
      assert {:ok, _deleted} = Groups.delete_group(owner, group)
    end
  end

  describe "listing respects visibility (through Authorization)" do
    setup do
      {community, owner} = community_with_owner_fixture()

      listed = group_fixture(community, name: "Listed", visibility: :public_listed)
      unlisted = group_fixture(community, name: "Unlisted", visibility: :public_link)
      community_wide = group_fixture(community, name: "CommunityWide", visibility: :community)
      private = group_fixture(community, name: "Private", visibility: :private)

      sealed_private =
        group_fixture(community, name: "SealedPrivate", visibility: :private, sealed: true)

      %{
        community: community,
        owner: owner,
        groups: %{
          listed: listed,
          unlisted: unlisted,
          community_wide: community_wide,
          private: private,
          sealed_private: sealed_private
        }
      }
    end

    test "anonymous visitors see only public_listed", %{community: community} do
      names = Groups.list_active_groups(nil, community) |> names()
      assert names == ["Listed"]
    end

    test "community members see community groups and public_listed, not unlisted/private",
         %{community: community} do
      member = member_fixture(community)
      names = Groups.list_active_groups(member, community) |> names()
      assert names == ["CommunityWide", "Listed"]
    end

    test "group members see their private and unlisted groups",
         %{community: community, groups: groups} do
      member = member_fixture(community)
      group_membership_fixture(groups.private, member)
      group_membership_fixture(groups.unlisted, member)

      names = Groups.list_active_groups(member, community) |> names()
      assert names == ["CommunityWide", "Listed", "Private", "Unlisted"]
    end

    test "community admins see everything except sealed groups they aren't in",
         %{community: community, owner: owner} do
      names = Groups.list_active_groups(owner, community) |> names()
      assert names == ["CommunityWide", "Listed", "Private", "Unlisted"]
      refute "SealedPrivate" in names
    end

    test "archived groups move to the archived list", %{community: community, groups: groups} do
      admin_member = group_member_fixture(groups.community_wide, :owner)
      {:ok, _archived} = Groups.archive_group(admin_member, groups.community_wide)

      active_names = Groups.list_active_groups(admin_member, community) |> names()
      refute "CommunityWide" in active_names

      archived_names = Groups.list_archived_groups(admin_member, community) |> names()
      assert "CommunityWide" in archived_names
    end
  end

  defp names(groups), do: groups |> Enum.map(& &1.name) |> Enum.sort()

  describe "membership lifecycle" do
    test "join_group honors join policy" do
      {community, _owner} = community_with_owner_fixture()
      open_group = group_fixture(community, join_policy: :open)
      invite_group = group_fixture(community, join_policy: :invite_only)
      member = member_fixture(community)

      assert {:ok, _membership} = Groups.join_group(member, open_group)
      assert {:error, :unauthorized} = Groups.join_group(member, invite_group)
    end

    test "owners cannot leave their group" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      group_owner = group_member_fixture(group, :owner)
      plain_member = group_member_fixture(group)

      assert {:error, :owner_cannot_leave} = Groups.leave_group(group_owner, group)
      assert {:ok, _deleted} = Groups.leave_group(plain_member, group)
    end

    test "add_member enforces the community-membership invariant" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      outsider = user_fixture()

      assert {:ok, _membership} = Groups.add_member(group, outsider)
      assert Kammer.Communities.get_membership(community, outsider)
    end
  end

  describe "join requests" do
    setup do
      {community, owner} = community_with_owner_fixture()
      group = group_fixture(community, join_policy: :request_approval)
      group_admin = group_member_fixture(group, :admin)
      %{community: community, owner: owner, group: group, group_admin: group_admin}
    end

    test "members request, admins approve", %{
      community: community,
      group: group,
      group_admin: group_admin
    } do
      requester = member_fixture(community)

      assert {:ok, request} = Groups.request_to_join(requester, group, "Let me in")
      assert {:ok, [pending]} = Groups.list_pending_join_requests(group_admin, group)
      assert pending.id == request.id

      assert {:ok, _membership} = Groups.approve_join_request(group_admin, group, request)
      assert Groups.get_membership(group, requester)
    end

    test "members request, admins deny", %{
      community: community,
      group: group,
      group_admin: group_admin
    } do
      requester = member_fixture(community)

      assert {:ok, request} = Groups.request_to_join(requester, group)
      assert {:ok, _denied} = Groups.deny_join_request(group_admin, group, request)
      refute Groups.get_membership(group, requester)
    end

    test "direct join is refused; duplicate requests are refused", %{
      community: community,
      group: group
    } do
      requester = member_fixture(community)

      assert {:error, :unauthorized} = Groups.join_group(requester, group)
      assert {:ok, _request} = Groups.request_to_join(requester, group)
      assert {:error, changeset} = Groups.request_to_join(requester, group)
      assert changeset.errors[:group_id]
    end

    test "plain members cannot see or approve requests", %{community: community, group: group} do
      requester = member_fixture(community)
      plain_group_member = group_member_fixture(group)

      {:ok, request} = Groups.request_to_join(requester, group)

      assert {:error, :unauthorized} =
               Groups.list_pending_join_requests(plain_group_member, group)

      assert {:error, :unauthorized} =
               Groups.approve_join_request(plain_group_member, group, request)
    end
  end
end
