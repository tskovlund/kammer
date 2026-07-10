defmodule KammerWeb.Api.DecisionsTest do
  @moduledoc """
  The decisions register over the API (issue #184): raising a motion,
  listing the register, recording the outcome, the feature gate, and the
  proposer/moderator split on recording.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Groups.Group
  alias Kammer.Repo

  defp decisions_context(attrs \\ []) do
    {community, _owner} = community_with_owner_fixture()

    group =
      community
      |> group_fixture(attrs)
      |> Group.features_changeset(%{"features" => ["feed", "decisions"]})
      |> Repo.update!()
      |> Map.put(:community, community)

    %{community: community, group: group, proposer: group_member_fixture(group)}
  end

  test "raise a motion, list the register, and record the outcome" do
    %{community: community, group: group, proposer: proposer} = decisions_context()

    created =
      proposer
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/decisions", %{
        title: "Hæv kontingentet",
        motion_markdown: "Kassen er tom."
      })
      |> tap(&assert_operation_response(&1, "decisions_create"))
      |> json_response(201)

    id = created["data"]["id"]
    assert created["data"]["post_id"]
    refute created["data"]["decided"]

    listed =
      proposer
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/decisions")
      |> tap(&assert_operation_response(&1, "decisions_index"))
      |> json_response(200)

    assert Enum.map(listed["data"], & &1["id"]) == [id]

    recorded =
      proposer
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/decisions/#{id}/outcome", %{
        outcome: "adopted",
        outcome_note: "8 for, 1 imod"
      })
      |> tap(&assert_operation_response(&1, "decisions_record_outcome"))
      |> json_response(200)

    assert recorded["data"]["outcome"] == "adopted"
    assert recorded["data"]["decided"]
  end

  test "a disabled tool is unreachable — create 404s" do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)

    member
    |> api_conn()
    |> post(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/decisions", %{
      title: "Nej"
    })
    |> json_response(404)
  end

  test "recording the outcome is the proposer's or a moderator's, not a member's" do
    %{community: community, group: group, proposer: proposer} = decisions_context()
    member = group_member_fixture(group)

    created =
      proposer
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/decisions", %{
        title: "Kontingent"
      })
      |> json_response(201)

    id = created["data"]["id"]

    member
    |> api_conn()
    |> put(~p"/api/v1/communities/#{community.slug}/decisions/#{id}/outcome", %{outcome: "noted"})
    |> json_response(403)
  end
end
