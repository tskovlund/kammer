defmodule KammerWeb.Api.AssignmentsTest do
  @moduledoc """
  Assignments over the API (issue #184): the create/claim/complete/
  comment path, the feature gate, the no-oracle 404 for a hidden
  assignment, and the manage-permission split on delete.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Groups.Group
  alias Kammer.Repo

  defp assignments_context(attrs \\ []) do
    {community, _owner} = community_with_owner_fixture()

    group =
      community
      |> group_fixture(attrs)
      |> Group.features_changeset(%{"features" => ["feed", "assignments"]})
      |> Repo.update!()
      |> Map.put(:community, community)

    %{community: community, group: group, creator: group_member_fixture(group)}
  end

  defp create_assignment(conn_user, community, group, title \\ "Kaffe") do
    conn_user
    |> api_conn()
    |> post(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/assignments", %{
      title: title
    })
    |> json_response(201)
  end

  test "create, claim, complete, and comment through the shared engine" do
    %{community: community, group: group, creator: creator} = assignments_context()
    member = group_member_fixture(group)

    created =
      creator
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/assignments", %{
        title: "Bage kage"
      })
      |> tap(&assert_operation_response(&1, "assignments_create"))
      |> json_response(201)

    id = created["data"]["id"]

    claimed =
      member
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/assignments/#{id}/claim")
      |> tap(&assert_operation_response(&1, "assignments_claim"))
      |> json_response(200)

    assert claimed["data"]["claimed_by_me"]
    assert length(claimed["data"]["claims"]) == 1

    done =
      member
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/assignments/#{id}/completion")
      |> tap(&assert_operation_response(&1, "assignments_complete"))
      |> json_response(200)

    assert done["data"]["completed"]

    commented =
      member
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/assignments/#{id}/comments", %{
        body_markdown: "Jeg køber bønner"
      })
      |> tap(&assert_operation_response(&1, "assignments_create_comment"))
      |> json_response(201)

    assert commented["data"]["body_markdown"] == "Jeg køber bønner"
  end

  test "a disabled tool is unreachable — create 404s" do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)

    member
    |> api_conn()
    |> post(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/assignments", %{
      title: "Nej"
    })
    |> json_response(404)
  end

  test "a hidden assignment answers 404 to an outsider (#156/#161)" do
    %{community: community, group: group, creator: creator} =
      assignments_context(visibility: :private)

    created = create_assignment(creator, community, group)
    id = created["data"]["id"]
    outsider = user_fixture()

    outsider
    |> api_conn()
    |> get(~p"/api/v1/communities/#{community.slug}/assignments/#{id}")
    |> json_response(404)

    # Reporting one of its comments reads the same — 404, never a 403
    # that would confirm the hidden discussion exists.
    comment =
      creator
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/assignments/#{id}/comments", %{
        body_markdown: "Skjult"
      })
      |> json_response(201)

    outsider
    |> api_conn()
    |> post(
      ~p"/api/v1/communities/#{community.slug}/assignments/#{id}/comments/#{comment["data"]["id"]}/report",
      %{reason: "x"}
    )
    |> json_response(404)
  end

  test "an assignment through another community's slug answers 404 (cross-tenant no-oracle)" do
    %{community: community, group: group, creator: creator} = assignments_context()
    created = create_assignment(creator, community, group)
    {other, other_owner} = community_with_owner_fixture()

    # A real assignment id reached through a DIFFERENT community's slug:
    # the community_id guard must 404, never leak it across the tenant
    # boundary — even to an owner authorized in their own community.
    other_owner
    |> api_conn()
    |> get(~p"/api/v1/communities/#{other.slug}/assignments/#{created["data"]["id"]}")
    |> json_response(404)
  end

  test "delete is creator-or-moderator; a plain member is refused" do
    %{community: community, group: group, creator: creator} = assignments_context()
    member = group_member_fixture(group)
    created = create_assignment(creator, community, group)
    id = created["data"]["id"]

    member
    |> api_conn()
    |> delete(~p"/api/v1/communities/#{community.slug}/assignments/#{id}")
    |> json_response(403)

    creator
    |> api_conn()
    |> delete(~p"/api/v1/communities/#{community.slug}/assignments/#{id}")
    |> tap(&assert_operation_response(&1, "assignments_delete"))
    |> json_response(200)
  end
end
