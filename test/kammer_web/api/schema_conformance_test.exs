defmodule KammerWeb.Api.SchemaConformanceTest do
  @moduledoc """
  Field-level drift guard (issue #151): real controller responses are
  validated against the OpenAPI document's response schema for their
  operation. The bijection test in `openapi_test.exs` proves every
  route is documented; this proves the documentation tells the truth
  about the bytes — issue #154 (single objects documented as arrays)
  was structurally invisible without it.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Events
  alias Kammer.Feed

  setup do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)
    %{community: community, group: group, member: member}
  end

  test "instance, home, communities, and groups match their schemas", %{
    community: community,
    group: group,
    member: member
  } do
    {:ok, _post} = Feed.create_post(member, group, %{"body_markdown" => "Hjemme"})

    member
    |> api_conn()
    |> get(~p"/api/v1/instance")
    |> assert_operation_response("instance_show")

    member
    |> api_conn()
    |> get(~p"/api/v1/home")
    |> assert_operation_response("home_show")

    member
    |> api_conn()
    |> get(~p"/api/v1/communities")
    |> assert_operation_response("communities_index")

    member
    |> api_conn()
    |> get(~p"/api/v1/communities/#{community.slug}/groups")
    |> assert_operation_response("groups_index")
  end

  test "post and comment responses match their schemas", %{
    community: community,
    group: group,
    member: member
  } do
    path = ~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/posts"

    created =
      member
      |> api_conn()
      |> post(path, %{"body_markdown" => "Via API"})
      |> tap(&assert_operation_response(&1, "posts_create"))
      |> json_response(201)

    member
    |> api_conn()
    |> get(path)
    |> assert_operation_response("posts_index")

    member
    |> api_conn()
    |> post(path <> "/#{created["data"]["id"]}/comments", %{"body_markdown" => "First!"})
    |> assert_operation_response("comments_create")
  end

  test "event responses match their schemas", %{
    community: community,
    group: group,
    member: member
  } do
    {:ok, event} =
      Events.create_event(member, group, %{
        "title" => "Skemafest",
        "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
      })

    member
    |> api_conn()
    |> get(~p"/api/v1/communities/#{community.slug}/events")
    |> assert_operation_response("events_index")

    member
    |> api_conn()
    |> put(~p"/api/v1/communities/#{community.slug}/events/#{event.id}/rsvp", %{
      "status" => "yes"
    })
    |> assert_operation_response("events_rsvp")

    member
    |> api_conn()
    |> get(~p"/api/v1/communities/#{community.slug}/events/#{event.id}")
    |> assert_operation_response("events_show")
  end
end
