defmodule KammerWeb.Api.ManagementTest do
  @moduledoc """
  Community, group, and instance-operator management over the API
  (issue #183), plus the #97 invite rate-limit mapping. Each endpoint is
  pinned on the axis that matters — the admin/operator may act, the
  ordinary member is refused — and the invite-flood budget maps to 429
  on the existing invite-create endpoint (the invite CRUD itself is
  #221's; only the rate limit is new here).
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Communities
  alias Kammer.Invitations

  describe "community creation" do
    test "the instance policy decides who may create; the creator becomes owner" do
      operator = instance_operator_fixture()
      ordinary = Kammer.AccountsFixtures.user_fixture()

      # Default policy is operators-only: an operator succeeds and the
      # `can_create_community` capability reports it before they try.
      assert operator
             |> api_conn()
             |> get(~p"/api/v1/instance")
             |> json_response(200)
             |> Map.fetch!("can_create_community")

      created =
        operator
        |> api_conn()
        |> post(~p"/api/v1/communities", %{name: "Sejlklubben", slug: unique_slug("sailing")})
        |> tap(&assert_operation_response(&1, "communities_create"))
        |> json_response(201)

      assert created["data"]["name"] == "Sejlklubben"
      # The creator owns it — the capability the owner alone holds.
      assert "manage_community" in created["data"]["viewer_can"]

      # An ordinary user under operators-only is refused, and the
      # capability told them so.
      refute ordinary
             |> api_conn()
             |> get(~p"/api/v1/instance")
             |> json_response(200)
             |> Map.fetch!("can_create_community")

      ordinary
      |> api_conn()
      |> post(~p"/api/v1/communities", %{name: "Nej", slug: unique_slug("nope")})
      |> json_response(403)

      # Opening the policy lets any user create.
      allow_any_user_community_creation()

      ordinary
      |> api_conn()
      |> post(~p"/api/v1/communities", %{name: "Vores klub", slug: unique_slug("ours")})
      |> json_response(201)
    end

    test "an invalid slug is rejected with 422 naming the slug field" do
      operator = instance_operator_fixture()

      %{"error" => %{"code" => "invalid_params", "details" => details}} =
        operator
        |> api_conn()
        |> post(~p"/api/v1/communities", %{name: "Bad", slug: "No Spaces Allowed"})
        |> json_response(422)

      # Pin the failure to the slug — not just any 422 — so the test can't
      # pass on an unrelated validation error.
      assert details["slug"]
    end
  end

  describe "community settings" do
    test "an admin updates settings; a member is refused" do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)

      body =
        owner
        |> api_conn()
        |> put(~p"/api/v1/communities/#{community.slug}", %{
          description: "Ny beskrivelse",
          accent_color: "#123456"
        })
        |> tap(&assert_operation_response(&1, "communities_update"))
        |> json_response(200)

      assert body["data"]["description"] == "Ny beskrivelse"
      assert body["data"]["accent_color"] == "#123456"

      member
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}", %{description: "Nej"})
      |> json_response(403)
    end
  end

  describe "group management" do
    setup do
      {community, owner} = community_with_owner_fixture()
      group = group_fixture(community)
      %{community: community, owner: owner, group: group}
    end

    test "a member creates a group; an outsider cannot", %{community: community} do
      member = member_fixture(community)
      outsider = Kammer.AccountsFixtures.user_fixture()

      created =
        member
        |> api_conn()
        |> post(~p"/api/v1/communities/#{community.slug}/groups", %{
          name: "Bestyrelsen",
          slug: unique_slug("board")
        })
        |> tap(&assert_operation_response(&1, "groups_create"))
        |> json_response(201)

      assert created["data"]["name"] == "Bestyrelsen"

      outsider
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/groups", %{
        name: "Nej",
        slug: unique_slug("nope")
      })
      |> json_response(403)
    end

    test "an admin edits, toggles features, and archives; a member is refused", %{
      community: community,
      owner: owner,
      group: group
    } do
      updated =
        owner
        |> api_conn()
        |> put(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}", %{
          description: "Opdateret",
          visibility: "private",
          join_policy: "request_approval",
          posting_policy: "admins_only",
          comment_policy: "off",
          approval_queue: true,
          version_retention: 5
        })
        |> tap(&assert_operation_response(&1, "groups_update"))
        |> json_response(200)

      # The full settings surface (issue #259) round-trips through the
      # serializer, not just name/description.
      assert updated["data"]["visibility"] == "private"
      assert updated["data"]["join_policy"] == "request_approval"
      assert updated["data"]["posting_policy"] == "admins_only"
      assert updated["data"]["comment_policy"] == "off"
      assert updated["data"]["approval_queue"] == true
      assert updated["data"]["version_retention"] == 5

      features =
        owner
        |> api_conn()
        |> put(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/features", %{
          features: ["feed", "events"]
        })
        |> tap(&assert_operation_response(&1, "groups_features"))
        |> json_response(200)

      assert "events" in features["data"]["features"]
      assert "files" not in features["data"]["features"]

      archived =
        owner
        |> api_conn()
        |> put(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/archive")
        |> tap(&assert_operation_response(&1, "groups_archive"))
        |> json_response(200)

      assert archived["data"]["archived"]

      owner
      |> api_conn()
      |> delete(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/archive")
      |> tap(&assert_operation_response(&1, "groups_unarchive"))
      |> json_response(200)

      member = group_member_fixture(group)

      member
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}", %{name: "Nej"})
      |> json_response(403)
    end

    test "a management verb on a group the caller can't see answers 404, not 403 (#156/#161)",
         %{community: community} do
      hidden = group_fixture(community, %{visibility: :private})
      outsider = Kammer.AccountsFixtures.user_fixture()

      # An unviewable group must be indistinguishable from a nonexistent
      # one — a 403 here would confirm the group exists.
      outsider
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/groups/#{hidden.slug}", %{name: "Nej"})
      |> json_response(404)
    end

    test "a group owner deletes the group; a group admin only gets 403", %{
      community: community,
      group: group
    } do
      group_owner = group_member_fixture(group, :owner)
      group_admin = group_member_fixture(group, :admin)

      # A group admin manages the group but doesn't own it — delete is
      # owner-or-community-admin only, and the group is visible to them,
      # so the refusal is an honest 403, not a hiding 404.
      group_admin
      |> api_conn()
      |> delete(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}")
      |> json_response(403)

      body =
        group_owner
        |> api_conn()
        |> delete(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}")
        |> tap(&assert_operation_response(&1, "groups_delete"))
        |> json_response(200)

      assert body["data"] == %{"status" => "deleted"}
      refute Kammer.Repo.get(Kammer.Groups.Group, group.id)
    end

    test "a community admin deletes a sealed group — the one admin power that pierces sealing",
         %{community: community, owner: owner} do
      sealed = group_fixture(community, %{sealed: true})

      owner
      |> api_conn()
      |> delete(~p"/api/v1/communities/#{community.slug}/groups/#{sealed.slug}")
      |> json_response(200)

      refute Kammer.Repo.get(Kammer.Groups.Group, sealed.id)
      # The context records the deletion in the community audit log.
      assert Enum.any?(
               Kammer.Audit.list_events(owner, community),
               &(&1.action == "group.deleted")
             )
    end

    test "a sealed flag in an update body is ignored — sealed is create-only", %{
      community: community,
      owner: owner,
      group: group
    } do
      refute group.sealed

      owner
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}", %{
        sealed: true,
        description: "Stadig useglet"
      })
      |> json_response(200)

      refute Kammer.Repo.get!(Kammer.Groups.Group, group.id).sealed
    end
  end

  describe "instance settings" do
    test "an operator reads and updates; a non-operator is refused" do
      operator = instance_operator_fixture()
      member = Kammer.AccountsFixtures.user_fixture()

      operator
      |> api_conn()
      |> get(~p"/api/v1/instance/settings")
      |> tap(&assert_operation_response(&1, "instance_settings"))
      |> json_response(200)

      updated =
        operator
        |> api_conn()
        |> put(~p"/api/v1/instance/settings", %{instance_name: "Vores Kammer"})
        |> tap(&assert_operation_response(&1, "instance_update_settings"))
        |> json_response(200)

      assert updated["data"]["instance_name"] == "Vores Kammer"
      assert Communities.get_instance_settings().instance_name == "Vores Kammer"

      member
      |> api_conn()
      |> get(~p"/api/v1/instance/settings")
      |> json_response(403)

      member
      |> api_conn()
      |> put(~p"/api/v1/instance/settings", %{instance_name: "Nej"})
      |> json_response(403)
    end

    test "the capability doc reports instance_operator per viewer (issue #259)" do
      operator = instance_operator_fixture()
      member = Kammer.AccountsFixtures.user_fixture()

      # Clients gate their operator surfaces on this flag instead of
      # probing an operator-only endpoint for the 403.
      assert operator
             |> api_conn()
             |> get(~p"/api/v1/instance")
             |> json_response(200)
             |> Map.fetch!("instance_operator")

      refute member
             |> api_conn()
             |> get(~p"/api/v1/instance")
             |> json_response(200)
             |> Map.fetch!("instance_operator")
    end
  end

  describe "invite rate limit (issue #97)" do
    test "an exhausted email-invite budget returns 429 at the invite endpoint" do
      {community, owner} = community_with_owner_fixture()

      # Spend the per-actor budget through the context, then prove the
      # existing invite-create endpoint maps the refusal onto 429.
      for n <- 1..20 do
        {:ok, _} =
          Invitations.create_community_invite(owner, community, %{
            "invited_email" => "seed#{n}@example.com"
          })
      end

      body =
        owner
        |> api_conn()
        |> post(~p"/api/v1/communities/#{community.slug}/invites", %{
          invited_email: "one-too-many@example.com"
        })
        |> json_response(429)

      assert body["error"]["code"] == "rate_limited"
    end
  end
end
