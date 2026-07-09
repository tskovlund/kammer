defmodule KammerWeb.Api.SchemaConformanceTest do
  @moduledoc """
  Field-level drift guard (issue #151): real controller responses are
  validated against the OpenAPI document's response schema for their
  operation. The bijection test in `openapi_test.exs` proves every
  route is documented; this catches documented fields with the wrong
  shape or type and missing required fields — issue #154 (single
  objects documented as arrays) was structurally invisible without it.
  One direction stays open: a serializer field the schema doesn't
  mention passes silently (schemas don't set `additionalProperties:
  false`), so new serializer fields still need a schema entry by hand.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Kammer.WebauthnHelper
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Accounts
  alias Kammer.Accounts.UserToken
  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Notifications
  alias Kammer.Repo

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

  test "notification responses match their schemas", %{group: group, member: member} do
    author = group_member_fixture(group)
    {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Conformance"})
    :ok = Notifications.fanout_post(post)

    member
    |> api_conn()
    |> get(~p"/api/v1/notifications")
    |> assert_operation_response("notifications_index")

    [notification | _] = Notifications.list_notifications(member)

    member
    |> api_conn()
    |> put(~p"/api/v1/notifications/#{notification.id}/read")
    |> assert_operation_response("notifications_mark_read")

    member
    |> api_conn()
    |> put(~p"/api/v1/notifications/read-all")
    |> assert_operation_response("notifications_mark_all_read")
  end

  test "auth exchange (both forms) and passkey responses match their schemas" do
    user = user_fixture()

    {magic_token, _hashed} = generate_user_magic_link_token(user)

    json_conn()
    |> post(~p"/api/v1/auth/exchange", %{"magic_token" => magic_token})
    |> assert_operation_response("auth_exchange")

    {code, code_token} = UserToken.build_login_code(user)
    Repo.insert!(code_token)

    json_conn()
    |> post(~p"/api/v1/auth/exchange", %{"email" => user.email, "code" => code})
    |> assert_operation_response("auth_exchange")

    origin = KammerWeb.Endpoint.url()
    registration_challenge = Accounts.new_passkey_registration_challenge(user, origin)
    ceremony = registration_ceremony(registration_challenge, origin)

    {:ok, _passkey} =
      Accounts.register_passkey(
        user,
        ceremony.attestation_object,
        ceremony.client_data_json,
        registration_challenge
      )

    challenge_body =
      json_conn()
      |> post(~p"/api/v1/auth/passkey/challenge")
      |> tap(&assert_operation_response(&1, "auth_passkey_challenge"))
      |> json_response(200)

    assertion =
      authentication_ceremony(
        %{
          bytes: Base.url_decode64!(challenge_body["challenge"], padding: false),
          rp_id: challenge_body["rp_id"]
        },
        origin,
        ceremony.credential_id,
        ceremony.key_pair
      )

    json_conn()
    |> post(~p"/api/v1/auth/passkey/verify", %{
      "challenge_token" => challenge_body["challenge_token"],
      "credential_id" => Base.url_encode64(assertion.credential_id, padding: false),
      "authenticator_data" => Base.url_encode64(assertion.authenticator_data, padding: false),
      "signature" => Base.url_encode64(assertion.signature, padding: false),
      "client_data_json" => Base.url_encode64(assertion.client_data_json, padding: false)
    })
    |> assert_operation_response("auth_passkey_verify")
  end

  test "push-subscription responses match their schemas", %{member: member} do
    member
    |> api_conn()
    |> post(~p"/api/v1/push-subscriptions", %{
      "endpoint" => "https://push.example.org/send/conformance",
      "keys" => %{"p256dh" => "key-material", "auth" => "auth-material"}
    })
    |> assert_operation_response("push_subscriptions_create")

    member
    |> api_conn()
    |> delete(~p"/api/v1/push-subscriptions?endpoint=https://push.example.org/send/x")
    |> assert_operation_response("push_subscriptions_delete")
  end

  # The auth operations answer unauthenticated requests — a bare JSON
  # conn, no device token.
  defp json_conn do
    put_req_header(build_conn(), "accept", "application/json")
  end
end
