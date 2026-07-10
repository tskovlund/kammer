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
      owner
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}", %{
        description: "Opdateret"
      })
      |> tap(&assert_operation_response(&1, "groups_update"))
      |> json_response(200)

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
