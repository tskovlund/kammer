defmodule KammerWeb.Api.GuestTest do
  @moduledoc """
  Tokenless guest surfaces over the API (issue #185, ADR 0013/0024):
  the request → confirm → manage signed-link flows for RSVPs, signup
  claims, and comments. Each test drives the real two-step wiring —
  request emails a confirm link, confirming records the action and
  emails a management link — then checks the management token lists and
  mutates exactly that guest's data. Invalid tokens get one neutral
  answer; the per-email rate limit is enforced.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import OpenApiSpex.TestAssertions
  import Swoosh.TestAssertions

  alias Kammer.Events
  alias Kammer.Feed

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
          "email" => "gaest@example.org",
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
        |> manage_token(~r{/guest/manage/([^\s"<]+)})

      body =
        public_conn()
        |> get(~p"/api/v1/guest/manage/#{manage_token}")
        |> tap(&assert_operation_response(&1, "guest_manage"))
        |> json_response(200)

      assert [%{"event_id" => event_id, "status" => "yes"}] = body["data"]["rsvps"]
      assert event_id == event.id

      updated =
        public_conn()
        |> put(~p"/api/v1/guest/manage/#{manage_token}/rsvps/#{event.id}", %{"status" => "no"})
        |> tap(&assert_operation_response(&1, "guest_set_rsvp"))
        |> json_response(200)

      assert [%{"status" => "no"}] = updated["data"]["rsvps"]

      public_conn()
      |> delete(~p"/api/v1/guest/manage/#{manage_token}")
      |> tap(&assert_operation_response(&1, "guest_erase"))
      |> json_response(200)

      # Erased: the token no longer resolves to any inventory.
      assert public_conn()
             |> get(~p"/api/v1/guest/manage/#{manage_token}")
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
        |> manage_token(~r{/guest/manage/([^\s"<]+)})

      body =
        public_conn()
        |> get(~p"/api/v1/guest/manage/#{manage_token}")
        |> json_response(200)

      assert [%{"pending_approval" => true, "body_markdown" => "Lovely event"}] =
               body["data"]["comments"]
    end
  end

  describe "neutral errors" do
    test "an invalid confirm or manage token is one neutral answer" do
      assert %{"error" => %{"code" => "not_found"}} =
               public_conn()
               |> post(~p"/api/v1/guest/rsvp/confirm", %{"token" => "not-a-token"})
               |> json_response(404)

      assert public_conn()
             |> get(~p"/api/v1/guest/manage/not-a-token")
             |> json_response(404)
    end
  end

  defp public_conn, do: put_req_header(build_conn(), "accept", "application/json")

  defp guest,
    do: %{
      "email" => "gaest#{System.unique_integer([:positive])}@example.org",
      "display_name" => "Gæst"
    }

  # Asserts the request answered 202 and validates it against the spec,
  # returning the conn so the confirm link can be read from the email.
  defp expect_confirmation(conn, status, operation_id) do
    assert json_response(conn, status)
    assert_operation_response(conn, operation_id)
    conn
  end

  defp confirm_token(_conn, regex), do: token_from_email(regex)
  defp manage_token(_conn, regex), do: token_from_email(regex)

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
