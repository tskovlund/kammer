defmodule KammerWeb.Api.PeopleTest do
  @moduledoc """
  The people rung over the API (issue #182): invites, the member
  directory with ADR 0020 redaction and filters, and community/group
  membership lifecycle. Permissions above all: every surface is
  exercised from both sides — the role that may, and the role that
  must be refused (403 where existence is already known, 404 where it
  must stay hidden).
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Accounts
  alias Kammer.AccountsFixtures
  alias Kammer.Communities
  alias Kammer.Groups
  alias Kammer.Invitations

  defp context(_tags) do
    {community, owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)
    %{community: community, owner: owner, group: group, member: member}
  end

  defp custom_field(owner, community, attrs) do
    {:ok, field} =
      Communities.create_custom_field(
        owner,
        community,
        Map.merge(%{"label" => "Felt", "field_type" => "text"}, attrs)
      )

    field
  end

  describe "invites" do
    setup :context

    test "an admin creates, lists, and revokes a community invite; a member is refused", %{
      community: community,
      owner: owner,
      member: member
    } do
      path = ~p"/api/v1/communities/#{community.slug}/invites"

      %{"data" => created} =
        owner
        |> api_conn()
        |> post(path, %{"max_uses" => 5})
        |> tap(&assert_operation_response(&1, "community_invites_create"))
        |> json_response(201)

      assert created["token"]
      assert created["group_id"] == nil

      %{"data" => [listed]} =
        owner
        |> api_conn()
        |> get(path)
        |> tap(&assert_operation_response(&1, "community_invites_index"))
        |> json_response(200)

      assert listed["id"] == created["id"]

      # A plain member may neither create nor list — the surface is
      # known (403), but a specific invite id must stay hidden (404),
      # indistinguishable from one that doesn't exist.
      member |> api_conn() |> post(path, %{}) |> json_response(403)
      member |> api_conn() |> get(path) |> json_response(403)

      member
      |> api_conn()
      |> delete(path <> "/#{created["id"]}")
      |> json_response(404)

      %{"data" => revoked} =
        owner
        |> api_conn()
        |> delete(path <> "/#{created["id"]}")
        |> tap(&assert_operation_response(&1, "invites_revoke"))
        |> json_response(200)

      assert revoked["revoked"] == true

      # A revoked token previews as no longer valid.
      build_conn()
      |> get(~p"/api/v1/invites/#{created["token"]}")
      |> json_response(404)
    end

    test "group invites are the group admin's, not every group member's", %{
      community: community,
      group: group,
      member: member
    } do
      admin = group_member_fixture(group, :admin)
      path = ~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/invites"

      %{"data" => created} =
        admin
        |> api_conn()
        |> post(path, %{})
        |> tap(&assert_operation_response(&1, "group_invites_create"))
        |> json_response(201)

      assert created["group_id"] == group.id

      %{"data" => [_invite]} =
        admin
        |> api_conn()
        |> get(path)
        |> tap(&assert_operation_response(&1, "group_invites_index"))
        |> json_response(200)

      member |> api_conn() |> post(path, %{}) |> json_response(403)

      # Revocation goes through the community-scoped route and answers
      # 404 to anyone who couldn't have listed the invite.
      member
      |> api_conn()
      |> delete(~p"/api/v1/communities/#{community.slug}/invites/#{created["id"]}")
      |> json_response(404)

      admin
      |> api_conn()
      |> delete(~p"/api/v1/communities/#{community.slug}/invites/#{created["id"]}")
      |> json_response(200)
    end

    test "preview is public; unknown and spent tokens are one neutral 404", %{
      community: community,
      owner: owner
    } do
      {:ok, invite} = Invitations.create_community_invite(owner, community)

      %{"data" => preview} =
        build_conn()
        |> get(~p"/api/v1/invites/#{invite.token}")
        |> tap(&assert_operation_response(&1, "invites_preview"))
        |> json_response(200)

      assert preview["community"]["slug"] == community.slug
      assert preview["group"] == nil

      %{"error" => %{"code" => code}} =
        build_conn() |> get(~p"/api/v1/invites/no-such-token") |> json_response(404)

      assert code == "not_found"
    end

    test "accepting joins and reports the required fields still missing", %{
      community: community,
      owner: owner
    } do
      field = custom_field(owner, community, %{"label" => "Instrument", "required" => true})
      {:ok, invite} = Invitations.create_community_invite(owner, community)
      joiner = AccountsFixtures.user_fixture()

      %{"data" => accepted} =
        joiner
        |> api_conn()
        |> post(~p"/api/v1/invites/#{invite.token}/accept")
        |> tap(&assert_operation_response(&1, "invites_accept"))
        |> json_response(200)

      assert accepted["community"]["my_role"] == "member"
      assert [%{"id" => missing_id}] = accepted["missing_required_fields"]
      assert missing_id == field.id
      assert Communities.get_membership(community, joiner)

      # The complete-profile step: answer the field, and the nag clears.
      %{"data" => profile} =
        joiner
        |> api_conn()
        |> put(~p"/api/v1/communities/#{community.slug}/profile", %{
          "values" => %{field.id => "Horn"}
        })
        |> tap(&assert_operation_response(&1, "community_profile_update"))
        |> json_response(200)

      assert profile["values"][field.id] == "Horn"
      assert profile["missing_required_field_ids"] == []
    end

    test "email-bound and use-limited invites enforce their bounds", %{
      community: community,
      owner: owner
    } do
      invited = AccountsFixtures.user_fixture()
      interloper = AccountsFixtures.user_fixture()

      {:ok, bound} =
        Invitations.create_community_invite(owner, community, %{
          "invited_email" => invited.email,
          "max_uses" => 1
        })

      interloper
      |> api_conn()
      |> post(~p"/api/v1/invites/#{bound.token}/accept")
      |> json_response(403)

      refute Communities.get_membership(community, interloper)

      invited
      |> api_conn()
      |> post(~p"/api/v1/invites/#{bound.token}/accept")
      |> json_response(200)

      # Used up: the next taker gets the same neutral 404 as a bad token.
      AccountsFixtures.user_fixture()
      |> api_conn()
      |> post(~p"/api/v1/invites/#{bound.token}/accept")
      |> json_response(404)
    end

    test "a group invite joins the group and the community in one step", %{
      community: community,
      group: group
    } do
      admin = group_member_fixture(group, :admin)
      {:ok, invite} = Invitations.create_group_invite(admin, group)
      joiner = AccountsFixtures.user_fixture()

      %{"data" => accepted} =
        joiner
        |> api_conn()
        |> post(~p"/api/v1/invites/#{invite.token}/accept")
        |> json_response(200)

      assert accepted["group"]["my_role"] == "member"
      assert Groups.get_membership(group, joiner)
      assert Communities.get_membership(community, joiner)
    end
  end

  describe "member directory" do
    setup :context

    test "the roster redacts contact and custom fields per viewer role (ADR 0020)", %{
      community: community,
      owner: owner,
      member: member
    } do
      members_field = custom_field(owner, community, %{"label" => "Instrument"})

      admins_field =
        custom_field(owner, community, %{"label" => "Kostbehov", "visibility" => "admins"})

      {:ok, member} =
        Accounts.update_user_settings(member, %{
          "contact_phone" => "12345678",
          "contact_phone_visibility" => "members",
          "contact_note" => "hemmelig",
          "contact_note_visibility" => "admins"
        })

      :ok =
        Communities.put_custom_field_values(member, community, %{
          members_field.id => "Horn",
          admins_field.id => "Vegetar"
        })

      path = ~p"/api/v1/communities/#{community.slug}/members"

      body =
        member
        |> api_conn()
        |> get(path)
        |> tap(&assert_operation_response(&1, "members_index"))
        |> json_response(200)

      # A plain member sees members-visible data only — the admins-only
      # field neither appears among the definitions nor in any values.
      assert Enum.map(body["fields"], & &1["id"]) == [members_field.id]
      row = Enum.find(body["data"], &(&1["user"]["id"] == member.id))
      assert row["custom_field_values"] == %{members_field.id => "Horn"}
      assert row["contact"] == %{"phone" => "12345678"}

      admin_body = owner |> api_conn() |> get(path) |> json_response(200)
      admin_row = Enum.find(admin_body["data"], &(&1["user"]["id"] == member.id))
      assert admins_field.id in Enum.map(admin_body["fields"], & &1["id"])
      assert admin_row["custom_field_values"][admins_field.id] == "Vegetar"
      assert admin_row["contact"] == %{"phone" => "12345678", "note" => "hemmelig"}

      # Outside the community there is no roster at all.
      AccountsFixtures.user_fixture() |> api_conn() |> get(path) |> json_response(403)
    end

    test "visible-field filters narrow the roster; hidden-field filters are inert", %{
      community: community,
      owner: owner,
      member: member
    } do
      field =
        custom_field(owner, community, %{
          "label" => "Stemme",
          "field_type" => "single_select",
          "options" => ["Sopran", "Bas"]
        })

      hidden = custom_field(owner, community, %{"label" => "Notat", "visibility" => "admins"})

      other = member_fixture(community)
      :ok = Communities.put_custom_field_values(member, community, %{field.id => "Bas"})
      :ok = Communities.put_custom_field_values(other, community, %{field.id => "Sopran"})
      :ok = Communities.put_custom_field_values(other, community, %{hidden.id => "X"})

      path = ~p"/api/v1/communities/#{community.slug}/members"

      %{"data" => filtered} =
        member
        |> api_conn()
        |> get(path, %{"filter" => %{field.id => "Bas"}})
        |> json_response(200)

      assert Enum.map(filtered, & &1["user"]["id"]) == [member.id]

      # Filtering on a field the viewer can't see must not act as a
      # value oracle — it is ignored, not honored.
      %{"data" => unfiltered} =
        member
        |> api_conn()
        |> get(path, %{"filter" => %{hidden.id => "X"}})
        |> json_response(200)

      # Owner + member + other: the whole roster, as if unfiltered.
      assert Enum.count(unfiltered) == 3
    end
  end

  describe "community membership" do
    setup :context

    test "role changes are the admin's; owner transitions are the owner's alone", %{
      community: community,
      owner: owner,
      member: member
    } do
      path = ~p"/api/v1/communities/#{community.slug}/members"

      %{"data" => %{"role" => "admin"}} =
        owner
        |> api_conn()
        |> put(path <> "/#{member.id}/role", %{"role" => "admin"})
        |> tap(&assert_operation_response(&1, "members_update_role"))
        |> json_response(200)

      # The freshly minted admin manages roles — but not the owner seat.
      target = member_fixture(community)

      member
      |> api_conn()
      |> put(path <> "/#{target.id}/role", %{"role" => "member"})
      |> json_response(200)

      member
      |> api_conn()
      |> put(path <> "/#{target.id}/role", %{"role" => "owner"})
      |> json_response(403)

      # A plain member is refused honestly; an outsider learns nothing.
      target
      |> api_conn()
      |> put(path <> "/#{member.id}/role", %{"role" => "member"})
      |> json_response(403)

      AccountsFixtures.user_fixture()
      |> api_conn()
      |> put(path <> "/#{member.id}/role", %{"role" => "member"})
      |> json_response(404)

      owner
      |> api_conn()
      |> put(path <> "/#{Ecto.UUID.generate()}/role", %{"role" => "member"})
      |> json_response(404)
    end

    test "admins remove members (groups included); members leave; owners can do neither", %{
      community: community,
      owner: owner,
      group: group,
      member: member
    } do
      base = "/api/v1/communities/#{community.slug}"

      owner
      |> api_conn()
      |> delete(base <> "/members/#{member.id}")
      |> tap(&assert_operation_response(&1, "members_remove"))
      |> json_response(200)

      refute Communities.get_membership(community, member)
      refute Groups.get_membership(group, member)

      leaver = member_fixture(community)

      leaver
      |> api_conn()
      |> delete(base <> "/membership")
      |> tap(&assert_operation_response(&1, "community_leave"))
      |> json_response(200)

      refute Communities.get_membership(community, leaver)

      # The owner seat can neither leave nor be removed.
      %{"error" => %{"code" => "owner_cannot_leave"}} =
        owner |> api_conn() |> delete(base <> "/membership") |> json_response(422)

      %{"error" => %{"code" => "owner_cannot_leave"}} =
        owner |> api_conn() |> delete(base <> "/members/#{owner.id}") |> json_response(422)

      # An outsider can't leave what they never joined, nor probe members.
      outsider = AccountsFixtures.user_fixture()
      outsider |> api_conn() |> delete(base <> "/membership") |> json_response(404)
      outsider |> api_conn() |> delete(base <> "/members/#{owner.id}") |> json_response(404)
    end
  end

  describe "group membership" do
    setup :context

    test "joining follows the group's policy", %{community: community, member: member} do
      open_group = group_fixture(community, join_policy: :open)
      gated = group_fixture(community, join_policy: :request_approval)
      closed = group_fixture(community, join_policy: :invite_only)

      join = fn group ->
        member
        |> api_conn()
        |> put(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/membership")
      end

      %{"status" => "joined"} =
        join.(open_group)
        |> tap(&assert_operation_response(&1, "group_join"))
        |> json_response(200)

      assert Groups.get_membership(open_group, member)
      # Idempotent: joining again is the same answer, not a refusal.
      %{"status" => "joined"} = join.(open_group) |> json_response(200)

      %{"status" => "requested"} = join.(gated) |> json_response(200)
      %{"status" => "requested"} = join.(gated) |> json_response(200)
      refute Groups.get_membership(gated, member)

      join.(closed) |> json_response(403)
    end

    test "the join-request queue is the approver's; ids stay hidden from members", %{
      community: community
    } do
      gated = group_fixture(community, join_policy: :request_approval)
      admin = group_member_fixture(gated, :admin)
      plain = group_member_fixture(gated)

      requester = member_fixture(community)
      denied_requester = member_fixture(community)
      {:ok, request} = Groups.request_to_join(requester, gated, "Må jeg?")
      {:ok, denial} = Groups.request_to_join(denied_requester, gated)

      base = "/api/v1/communities/#{community.slug}/groups/#{gated.slug}/join-requests"

      %{"data" => listed} =
        admin
        |> api_conn()
        |> get(base)
        |> tap(&assert_operation_response(&1, "join_requests_index"))
        |> json_response(200)

      assert Enum.sort(Enum.map(listed, & &1["id"])) == Enum.sort([request.id, denial.id])

      # A plain member can't list the queue, and a known request id
      # answers 404 for them — requests are admin-only information.
      plain |> api_conn() |> get(base) |> json_response(403)

      plain
      |> api_conn()
      |> put(base <> "/#{request.id}/approval")
      |> json_response(404)

      admin
      |> api_conn()
      |> put(base <> "/#{request.id}/approval")
      |> tap(&assert_operation_response(&1, "join_requests_approve"))
      |> json_response(200)

      assert Groups.get_membership(gated, requester)

      admin
      |> api_conn()
      |> delete(base <> "/#{denial.id}")
      |> tap(&assert_operation_response(&1, "join_requests_deny"))
      |> json_response(200)

      refute Groups.get_membership(gated, denied_requester)
      %{"data" => []} = admin |> api_conn() |> get(base) |> json_response(200)

      # Hidden group, hidden queue: outsiders never reach the gate.
      hidden = group_fixture(community, visibility: :private)
      outsider = AccountsFixtures.user_fixture()

      outsider
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/groups/#{hidden.slug}/join-requests")
      |> json_response(403)
    end

    test "member list, role changes, removal, and leaving", %{
      community: community,
      group: group,
      member: member
    } do
      admin = group_member_fixture(group, :admin)
      base = "/api/v1/communities/#{community.slug}/groups/#{group.slug}"

      %{"data" => members} =
        member
        |> api_conn()
        |> get(base <> "/members")
        |> tap(&assert_operation_response(&1, "group_members_index"))
        |> json_response(200)

      assert Enum.count(members) == 2

      %{"data" => %{"role" => "admin"}} =
        admin
        |> api_conn()
        |> put(base <> "/members/#{member.id}/role", %{"role" => "admin"})
        |> tap(&assert_operation_response(&1, "group_members_update_role"))
        |> json_response(200)

      # A plain member is refused honestly on a roster they can see.
      demoted = group_member_fixture(group)

      demoted
      |> api_conn()
      |> put(base <> "/members/#{member.id}/role", %{"role" => "member"})
      |> json_response(403)

      demoted
      |> api_conn()
      |> delete(base <> "/members/#{member.id}")
      |> json_response(403)

      admin
      |> api_conn()
      |> delete(base <> "/members/#{demoted.id}")
      |> tap(&assert_operation_response(&1, "group_members_remove"))
      |> json_response(200)

      refute Groups.get_membership(group, demoted)

      member
      |> api_conn()
      |> delete(base <> "/membership")
      |> tap(&assert_operation_response(&1, "group_leave"))
      |> json_response(200)

      refute Groups.get_membership(group, member)
      member |> api_conn() |> delete(base <> "/membership") |> json_response(404)

      # The group owner cannot leave.
      owned_group = group_fixture(community)
      group_owner = group_member_fixture(owned_group, :owner)
      owned_base = "/api/v1/communities/#{community.slug}/groups/#{owned_group.slug}"

      %{"error" => %{"code" => "owner_cannot_leave"}} =
        group_owner |> api_conn() |> delete(owned_base <> "/membership") |> json_response(422)
    end
  end

  describe "notification level" do
    setup :context

    test "read and set the per-group level (SPEC §9)", %{
      community: community,
      group: group,
      member: member
    } do
      base = "/api/v1/communities/#{community.slug}/groups/#{group.slug}"

      %{"data" => %{"level" => "highlights", "default_level" => "highlights"}} =
        member
        |> api_conn()
        |> get(base <> "/notification-level")
        |> tap(&assert_operation_response(&1, "notification_level_show"))
        |> json_response(200)

      %{"data" => %{"level" => "muted"}} =
        member
        |> api_conn()
        |> put(base <> "/notification-level", %{"level" => "muted"})
        |> tap(&assert_operation_response(&1, "notification_level_update"))
        |> json_response(200)

      %{"data" => %{"level" => "muted"}} =
        member |> api_conn() |> get(base <> "/notification-level") |> json_response(200)

      member
      |> api_conn()
      |> put(base <> "/notification-level", %{"level" => "loudest"})
      |> json_response(400)

      # Broadcast groups default to everything (announcements announce).
      broadcast = group_fixture(community, posting_policy: :admins_only)

      %{"data" => %{"level" => "everything", "default_level" => "everything"}} =
        member
        |> api_conn()
        |> get(
          ~p"/api/v1/communities/#{community.slug}/groups/#{broadcast.slug}/notification-level"
        )
        |> json_response(200)
    end
  end
end
