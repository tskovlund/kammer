defmodule KammerWeb.Api.AvailabilityTest do
  @moduledoc """
  Date-finding polls over the API (issue #184): the create/respond/close
  happy path, converting the winning date into an event, the feature
  gate (a disabled tool is unreachable), the no-oracle 404 for a poll the
  caller can't see, and the manage-permission split.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Groups.Group
  alias Kammer.Repo

  defp poll_context(attrs \\ []) do
    {community, _owner} = community_with_owner_fixture()

    group =
      community
      |> group_fixture(attrs)
      |> Group.features_changeset(%{"features" => ["feed", "events", "availability"]})
      |> Repo.update!()
      |> Map.put(:community, community)

    %{community: community, group: group, creator: group_member_fixture(group)}
  end

  defp iso(hours),
    do: DateTime.utc_now(:second) |> DateTime.add(hours, :hour) |> DateTime.to_iso8601()

  test "create, answer, and convert the winning date into an event" do
    %{community: community, group: group, creator: creator} = poll_context()
    member = group_member_fixture(group)

    created =
      creator
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/availability", %{
        title: "Prøve",
        options: [iso(24), iso(48)]
      })
      |> tap(&assert_operation_response(&1, "availability_create"))
      |> json_response(201)

    poll_id = created["data"]["id"]
    [option, winner] = created["data"]["options"]

    answered =
      member
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/availability/#{poll_id}/responses", %{
        option_id: option["id"],
        answer: "yes"
      })
      |> tap(&assert_operation_response(&1, "availability_respond"))
      |> json_response(200)

    assert Enum.find(answered["data"]["options"], &(&1["id"] == option["id"]))["my_answer"] ==
             "yes"

    converted =
      creator
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/availability/#{poll_id}/conversion", %{
        option_id: winner["id"]
      })
      |> tap(&assert_operation_response(&1, "availability_convert"))
      |> json_response(200)

    assert converted["data"]["closed"]
    assert converted["data"]["converted_event_id"]
  end

  test "a disabled tool is unreachable — create 404s" do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)

    member
    |> api_conn()
    |> post(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/availability", %{
      title: "Nej",
      options: [iso(24)]
    })
    |> json_response(404)
  end

  test "a poll in a hidden group is 404, not 403, to an outsider (#156/#161)" do
    %{community: community, group: group, creator: creator} = poll_context(visibility: :private)

    created =
      creator
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/availability", %{
        title: "Hemmelig",
        options: [iso(24)]
      })
      |> json_response(201)

    poll_id = created["data"]["id"]
    outsider = user_fixture()

    outsider
    |> api_conn()
    |> get(~p"/api/v1/communities/#{community.slug}/availability/#{poll_id}")
    |> json_response(404)
  end

  test "closing is the creator's or a moderator's, not an ordinary member's" do
    %{community: community, group: group, creator: creator} = poll_context()
    member = group_member_fixture(group)

    created =
      creator
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/availability", %{
        title: "Prøve",
        options: [iso(24)]
      })
      |> json_response(201)

    poll_id = created["data"]["id"]

    member
    |> api_conn()
    |> put(~p"/api/v1/communities/#{community.slug}/availability/#{poll_id}/closure")
    |> json_response(403)

    creator
    |> api_conn()
    |> put(~p"/api/v1/communities/#{community.slug}/availability/#{poll_id}/closure")
    |> tap(&assert_operation_response(&1, "availability_close"))
    |> json_response(200)
  end
end
