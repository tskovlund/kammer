defmodule Kammer.InvitationsTest do
  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Swoosh.TestAssertions

  alias Kammer.Groups
  alias Kammer.Invitations

  describe "creating invites" do
    test "community invites require community admin" do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)

      assert {:error, :unauthorized} = Invitations.create_community_invite(member, community)
      assert {:ok, invite} = Invitations.create_community_invite(owner, community)
      assert invite.token
      assert invite.group_id == nil
    end

    test "group invites require group admin powers; sealed excludes community admins" do
      {community, community_owner} = community_with_owner_fixture()
      group = group_fixture(community)
      sealed_group = group_fixture(community, sealed: true, visibility: :private)
      group_admin = group_member_fixture(group, :admin)
      sealed_admin = group_member_fixture(sealed_group, :admin)

      assert {:ok, _invite} = Invitations.create_group_invite(group_admin, group)
      assert {:ok, _invite} = Invitations.create_group_invite(community_owner, group)

      assert {:ok, _invite} = Invitations.create_group_invite(sealed_admin, sealed_group)

      assert {:error, :unauthorized} =
               Invitations.create_group_invite(community_owner, sealed_group)
    end

    test "email invites are delivered" do
      {community, owner} = community_with_owner_fixture()
      drain_delivered_emails()

      assert {:ok, _invite} =
               Invitations.create_community_invite(owner, community, %{
                 "invited_email" => "trumpet@example.com"
               })

      assert_email_sent(fn email ->
        Enum.any?(email.to, fn {_name, address} -> address == "trumpet@example.com" end)
      end)
    end
  end

  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end

  describe "redeem_invite/2" do
    test "community invite joins the community" do
      {community, owner} = community_with_owner_fixture()
      {:ok, invite} = Invitations.create_community_invite(owner, community)
      newcomer = user_fixture()

      assert {:ok, _redeemed} = Invitations.redeem_invite(newcomer, invite.token)
      assert Kammer.Communities.get_membership(community, newcomer)
    end

    test "group invite joins group and community" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, join_policy: :invite_only, visibility: :private)
      group_owner = group_member_fixture(group, :owner)
      {:ok, invite} = Invitations.create_group_invite(group_owner, group)
      newcomer = user_fixture()

      assert {:ok, _redeemed} = Invitations.redeem_invite(newcomer, invite.token)
      assert Groups.get_membership(group, newcomer)
      assert Kammer.Communities.get_membership(community, newcomer)
    end

    test "expired, revoked, and used-up invites are refused" do
      {community, owner} = community_with_owner_fixture()

      {:ok, expired} =
        Invitations.create_community_invite(owner, community, %{
          "expires_at" => DateTime.add(DateTime.utc_now(:second), -60)
        })

      {:ok, limited} = Invitations.create_community_invite(owner, community, %{"max_uses" => 1})
      {:ok, revoked} = Invitations.create_community_invite(owner, community)
      {:ok, revoked} = Invitations.revoke_invite(owner, revoked)

      first_user = user_fixture()
      second_user = user_fixture()

      assert {:error, :invalid} = Invitations.redeem_invite(first_user, expired.token)
      assert {:error, :invalid} = Invitations.redeem_invite(first_user, revoked.token)

      assert {:ok, _redeemed} = Invitations.redeem_invite(first_user, limited.token)
      assert {:error, :invalid} = Invitations.redeem_invite(second_user, limited.token)

      assert {:error, :invalid} = Invitations.redeem_invite(first_user, "no-such-token")
    end

    test "email-bound invites require a matching account email" do
      {community, owner} = community_with_owner_fixture()

      {:ok, invite} =
        Invitations.create_community_invite(owner, community, %{
          "invited_email" => "horn@example.com"
        })

      wrong_user = user_fixture()
      right_user = unconfirmed_user_fixture(email: "horn@example.com")

      assert {:error, :email_mismatch} = Invitations.redeem_invite(wrong_user, invite.token)
      assert {:ok, _redeemed} = Invitations.redeem_invite(right_user, invite.token)
    end

    test "redeeming twice is idempotent for membership and counts uses" do
      {community, owner} = community_with_owner_fixture()
      {:ok, invite} = Invitations.create_community_invite(owner, community)
      newcomer = user_fixture()

      assert {:ok, _first} = Invitations.redeem_invite(newcomer, invite.token)
      assert {:ok, second} = Invitations.redeem_invite(newcomer, invite.token)
      assert second.use_count == 2
      assert Kammer.Communities.get_membership(community, newcomer)
    end
  end

  describe "listing and revoking" do
    test "list_invites is permission-gated and revocation works" do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)
      {:ok, invite} = Invitations.create_community_invite(owner, community)

      assert {:error, :unauthorized} = Invitations.list_invites(member, community)
      assert {:ok, [listed]} = Invitations.list_invites(owner, community)
      assert listed.id == invite.id

      assert {:ok, _revoked} = Invitations.revoke_invite(owner, invite)
      assert {:ok, []} = Invitations.list_invites(owner, community)
    end
  end
end
