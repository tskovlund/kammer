defmodule KammerWeb.Api.SearchTest do
  @moduledoc """
  Global search over the API (issue #184, SPEC §16): a match surfaces in
  its section, and the endpoint inherits the context's invariant —
  content from a group the viewer can't see listed never surfaces (a
  transport check that the narrowing is actually applied, not the
  exhaustive property test that already lives in the context suite).
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Feed

  test "a matching post surfaces for a member" do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :community)
    member = group_member_fixture(group)

    {:ok, _post} =
      Feed.create_post(member, group, %{"body_markdown" => "Generalprøven er flyttet"})

    body =
      member
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/search?q=generalprøven")
      |> tap(&assert_operation_response(&1, "search"))
      |> json_response(200)

    assert length(body["data"]["posts"]) == 1
    assert body["data"]["comments"] == []
  end

  test "a private group's content never surfaces to a non-member" do
    {community, _owner} = community_with_owner_fixture()
    private = group_fixture(community, visibility: :private)
    private_member = group_member_fixture(private)

    {:ok, _post} = Feed.create_post(private_member, private, %{"body_markdown" => "Nålestak"})

    outsider = user_fixture()

    body =
      outsider
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/search?q=nålestak")
      |> json_response(200)

    assert body["data"]["posts"] == []
  end
end
