defmodule KammerWeb.Api.GuestTest do
  @moduledoc """
  Tokenless guest surfaces over the API (issue #185, ADR 0013/0024):
  the request → confirm → manage signed-link flows for RSVPs, signup
  claims, and comments. Each test drives the real two-step wiring —
  request emails a confirm link, confirming records the action and
  emails a management link — then checks the management token lists and
  mutates exactly that guest's data. Invalid tokens get one neutral
  answer; the per-email rate limit is enforced.

  Since issue #230 (ADR 0026) the management token rides an
  `Authorization: Bearer` header, not the URL — `bearer_conn/1` builds
  the header, and `manage_token/1` reads it from the email link's URL
  fragment (`#token`, not `/token`).
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers, only: [bearer_conn: 1]
  import OpenApiSpex.TestAssertions
  import Swoosh.TestAssertions

  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Guests.Token, as: GuestToken

  setup do
    {community, _owner} = community_with_owner_fixture()

    group =
      group_fixture(community,
        visibility: :public_listed,
        comment_policy: :members_and_guests
      )

    member = group_member_fixture(group)

    {:ok, event} =
      Events.create_event(member, group, %{
        "title" => "Open concert",
        "starts_at" => DateTime.add(DateTime.utc_now(:second), 72, :hour)
      })

    {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Welcome, guests"})

    drain_emails()
    %{community: community, group: group, member: member, event: event, post: post}
  end

  describe "RSVP request → confirm → manage" do
    test "a guest RSVPs, confirms, and manages their answer", %{
      community: community,
      event: event
    } do
      token =
        public_conn()
        |> post(~p"/api/v1/communities/#{community.slug}/events/#{event.id}/guest-rsvp", %{
          "email" => "gaest-#{System.unique_integer([:positive])}@example.org",
          "display_name" => "Gæsten",
          "status" => "yes"
        })
        |> expect_confirmation(202, "guest_request_rsvp")
        |> confirm_token(~r{/guest/rsvp/confirm/([^\s"<]+)})

      manage_token =
        public_conn()
        |> post(~p"/api/v1/guest/rsvp/confirm", %{"token" => token})
        |> tap(&assert_operation_response(&1, "guest_confirm_rsvp"))
        |> tap(fn conn ->
          body = json_response(conn, 200)
          assert body["data"]["guest_name"] == "Gæsten"
          assert body["data"]["redirect_path"] =~ "/events/#{event.id}"
        end)
        |> manage_token()

      body =
        bearer_conn(manage_token)
        |> get(~p"/api/v1/guest/manage")
        |> tap(&assert_operation_response(&1, "guest_manage"))
        |> json_response(200)

      assert [%{"event_id" => event_id, "status" => "yes"}] = body["data"]["rsvps"]
      assert event_id == event.id

      updated =
        bearer_conn(manage_token)
        |> put(~p"/api/v1/guest/manage/rsvps/#{event.id}", %{"status" => "no"})
        |> tap(&assert_operation_response(&1, "guest_set_rsvp"))
        |> json_response(200)

      assert [%{"status" => "no"}] = updated["data"]["rsvps"]

      bearer_conn(manage_token)
      |> delete(~p"/api/v1/guest/manage")
      |> tap(&assert_operation_response(&1, "guest_erase"))
      |> json_response(200)

      # Erased: the token no longer resolves to any inventory.
      assert bearer_conn(manage_token)
             |> get(~p"/api/v1/guest/manage")
             |> json_response(404)
    end

    test "the per-email rate limit is enforced", %{community: community, event: event} do
      params = %{"email" => "spam@example.org", "display_name" => "Gæst", "status" => "yes"}
      path = ~p"/api/v1/communities/#{community.slug}/events/#{event.id}/guest-rsvp"

      for _attempt <- 1..3 do
        assert public_conn() |> post(path, params) |> json_response(202)
      end

      assert %{"error" => %{"code" => "rate_limited"}} =
               public_conn() |> post(path, params) |> json_response(429)
    end
  end

  describe "signup claim" do
    test "a guest claims a slot, and a full slot is refused", %{
      community: community,
      event: event,
      member: member
    } do
      {:ok, open} = Events.create_slot(member, event, %{"title" => "Bar shift", "capacity" => 4})
      {:ok, full} = Events.create_slot(member, event, %{"title" => "Solo", "capacity" => 1})
      {:ok, _claim} = Events.claim_slot(member, full)

      base = ~p"/api/v1/communities/#{community.slug}/events/#{event.id}"

      token =
        public_conn()
        |> post("#{base}/slots/#{open.id}/guest-claim", guest())
        |> expect_confirmation(202, "guest_request_claim")
        |> confirm_token(~r{/guest/claim/confirm/([^\s"<]+)})

      public_conn()
      |> post(~p"/api/v1/guest/claim/confirm", %{"token" => token})
      |> tap(&assert_operation_response(&1, "guest_confirm_claim"))
      |> json_response(200)

      assert %{"error" => %{"code" => "slot_full"}} =
               public_conn()
               |> post("#{base}/slots/#{full.id}/guest-claim", guest())
               |> json_response(422)
    end
  end

  describe "comment" do
    test "a guest comment is confirmed into moderation", %{
      community: community,
      group: group,
      post: post
    } do
      token =
        public_conn()
        |> post(
          ~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/posts/#{post.id}/guest-comment",
          Map.put(guest(), "body_markdown", "Lovely event")
        )
        |> expect_confirmation(202, "guest_request_comment")
        |> confirm_token(~r{/guest/comment/confirm/([^\s"<]+)})

      manage_token =
        public_conn()
        |> post(~p"/api/v1/guest/comment/confirm", %{"token" => token})
        |> tap(&assert_operation_response(&1, "guest_confirm_comment"))
        |> manage_token()

      body =
        bearer_conn(manage_token)
        |> get(~p"/api/v1/guest/manage")
        |> json_response(200)

      assert [%{"pending_approval" => true, "body_markdown" => "Lovely event"}] =
               body["data"]["comments"]
    end
  end

  describe "cross-guest isolation (#156/#161)" do
    test "a manage token cannot release another guest's claim", %{
      community: community,
      event: event,
      member: member
    } do
      {:ok, slot} = Events.create_slot(member, event, %{"title" => "Bar shift", "capacity" => 4})
      base = ~p"/api/v1/communities/#{community.slug}/events/#{event.id}"

      attacker = claim_manage_token(base, slot)
      victim = claim_manage_token(base, slot)

      claim_id =
        bearer_conn(victim)
        |> get(~p"/api/v1/guest/manage")
        |> json_response(200)
        |> get_in(["data", "claims", Access.at(0), "claim_id"])

      # The attacker holds a *valid* manage token, but the claim id belongs
      # to another guest: the per-identity scoping in the context must
      # answer a neutral 404 and leave the victim's claim untouched — the
      # token authorizes the caller, never an arbitrary sub-resource id.
      bearer_conn(attacker)
      |> delete(~p"/api/v1/guest/manage/claims/#{claim_id}")
      |> json_response(404)

      assert [%{"claim_id" => ^claim_id}] =
               bearer_conn(victim)
               |> get(~p"/api/v1/guest/manage")
               |> json_response(200)
               |> get_in(["data", "claims"])
    end
  end

  describe "neutral errors" do
    test "an invalid confirm or manage token is one neutral answer" do
      assert %{"error" => %{"code" => "not_found"}} =
               public_conn()
               |> post(~p"/api/v1/guest/rsvp/confirm", %{"token" => "not-a-token"})
               |> json_response(404)

      assert bearer_conn("not-a-token")
             |> get(~p"/api/v1/guest/manage")
             |> json_response(404)
    end

    test "a newsletter one-click unsubscribe token is powerless as a manage Bearer token (issue #233)" do
      # The scoped List-Unsubscribe token (a different salt entirely,
      # `Kammer.Guests.Token.verify_unsubscribe/1`) must never authorize
      # anything on the manage surface, even though it's a validly
      # signed guest token — the same neutral 404 as any other bad
      # token, never a distinguishable answer.
      scoped_token = GuestToken.sign_unsubscribe(%{subscription_id: Ecto.UUID.generate()})

      assert bearer_conn(scoped_token)
             |> get(~p"/api/v1/guest/manage")
             |> json_response(404)
    end

    test "a manage request with no Authorization header, or a malformed one, is the same neutral 404" do
      assert public_conn()
             |> get(~p"/api/v1/guest/manage")
             |> json_response(404)

      assert public_conn()
             |> put_req_header("authorization", "not-a-bearer-header")
             |> get(~p"/api/v1/guest/manage")
             |> json_response(404)
    end

    test "an authentic token with a missing status gets the deliberate 400", %{
      community: community,
      event: event,
      member: member
    } do
      {:ok, slot} = Events.create_slot(member, event, %{"title" => "Bar shift", "capacity" => 4})
      base = ~p"/api/v1/communities/#{community.slug}/events/#{event.id}"
      token = claim_manage_token(base, slot)

      assert %{"error" => %{"code" => "bad_request", "message" => "status" <> _rest}} =
               bearer_conn(token)
               |> put(~p"/api/v1/guest/manage/rsvps/#{event.id}", %{})
               |> json_response(400)
    end

    test "request-shape errors are gated behind a valid token — a bad token can't probe the body" do
      # A forged token with a malformed body must get the neutral 404,
      # never the shape-specific 400: the body is only inspected once the
      # token is proven authentic, so 400-vs-404 never distinguishes a
      # good token from a bad one (ADR 0026's no-oracle property).
      assert bearer_conn("not-a-token")
             |> put(~p"/api/v1/guest/manage/rsvps/#{Ecto.UUID.generate()}", %{})
             |> json_response(404)
    end
  end

  # Each request comes from a fresh TEST-NET-1 (RFC 5737, 192.0.2.0/24)
  # address so the per-IP guest budget spent here can never collide with
  # another async test — or with the LiveView guest-flow tests, which
  # share the stubbed peer address. Only the email dimension is exercised
  # across requests (the rate-limit test below); the IP is deliberately
  # unique so it never confounds that assertion.
  defp public_conn do
    ip = {192, 0, 2, rem(System.unique_integer([:positive]), 254) + 1}

    build_conn()
    |> Map.put(:remote_ip, ip)
    |> put_req_header("accept", "application/json")
  end

  # The management token's transport since ADR 0026: an Authorization
  # header, not a URL segment.

  defp guest,
    do: %{
      "email" => "gaest#{System.unique_integer([:positive])}@example.org",
      "display_name" => "Gæst"
    }

  # Requests and confirms a guest slot claim, returning that guest's own
  # management token (read from the confirmation email).
  defp claim_manage_token(base, slot) do
    confirm =
      public_conn()
      |> post("#{base}/slots/#{slot.id}/guest-claim", guest())
      |> confirm_token(~r{/guest/claim/confirm/([^\s"<]+)})

    public_conn()
    |> post(~p"/api/v1/guest/claim/confirm", %{"token" => confirm})
    |> manage_token()
  end

  # Asserts the request answered 202 and validates it against the spec,
  # returning the conn so the confirm link can be read from the email.
  defp expect_confirmation(conn, status, operation_id) do
    assert json_response(conn, status)
    assert_operation_response(conn, operation_id)
    conn
  end

  defp confirm_token(_conn, regex), do: token_from_email(regex)

  # The management link carries its token in the URL fragment
  # (`#token`, ADR 0026), not a path segment.
  defp manage_token(_conn), do: token_from_email(~r{/guest/manage#([^\s"<]+)})

  defp token_from_email(regex) do
    assert_email_sent(fn email ->
      [captured] = Regex.run(regex, email.text_body, capture: :all_but_first)
      send(self(), {:extracted_token, captured})
      true
    end)

    assert_received {:extracted_token, token}
    token
  end

  defp drain_emails do
    receive do
      {:email, _email} -> drain_emails()
    after
      0 -> :ok
    end
  end
end
