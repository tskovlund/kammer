defmodule KammerWeb.Api.SchemaConformanceTest do
  @moduledoc """
  Field-level drift guard (issue #151): real controller responses are
  validated against the OpenAPI document's response schema for their
  operation. The bijection test in `openapi_test.exs` proves every
  route is documented; conformance taps catch documented fields with
  the wrong shape or type and missing required fields — issue #154
  (single objects documented as arrays) was structurally invisible
  without them. Most taps live inline in the behavior tests that
  already drive each operation (`assert_operation_response` at the
  point of the real interaction — the idiom feed_writes/event_writes/
  file_library/resources/notifications/auth use); this file keeps only
  the read-only operations no behavior test drives. One direction
  stays open: a serializer field the schema doesn't mention passes
  silently (schemas don't set `additionalProperties: false`), so new
  serializer fields still need a schema entry by hand.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

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
end
