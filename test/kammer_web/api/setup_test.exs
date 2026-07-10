defmodule KammerWeb.Api.SetupTest do
  # async: false — the setup token lives in :persistent_term (global),
  # and completion erases it.
  use KammerWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions

  alias Kammer.Setup

  # Exercise the genuine pre-setup instance; ConnCase otherwise marks
  # setup done so routing tests see a normal instance.
  @moduletag :setup_pending

  @complete_body %{
    "operator" => %{"email" => "op@example.org", "display_name" => "The Operator"},
    "instance" => %{"instance_name" => "Kammeret", "default_locale" => "en"},
    "community" => %{"name" => "First Community", "slug" => "first"},
    "group" => %{"name" => "General", "slug" => "general"},
    "demo_data" => false
  }

  test "reports pending status before setup completes" do
    assert %{"setup_completed" => false} =
             public_conn()
             |> get(~p"/api/v1/setup")
             |> tap(&assert_operation_response(&1, "setup_status"))
             |> json_response(200)
  end

  test "completing with the token locks setup; the token no longer works" do
    token = Setup.ensure_setup_token()

    body =
      public_conn()
      |> post(~p"/api/v1/setup", Map.put(@complete_body, "token", token))
      |> tap(&assert_operation_response(&1, "setup_complete"))
      |> json_response(201)

    assert body["data"]["community_slug"] == "first"
    assert body["data"]["group_slug"] == "general"
    assert is_binary(body["data"]["invite_token"])
    assert body["data"]["invite_url"] =~ body["data"]["invite_token"]
    assert Setup.completed?()

    # The operator's first magic link is the live SMTP test.
    assert_receive {:email, %Swoosh.Email{to: [{_name, "op@example.org"}]}}

    # The token was erased on lock: a second attempt is one neutral 403.
    assert %{"error" => %{"code" => "forbidden"}} =
             public_conn()
             |> post(~p"/api/v1/setup", Map.put(@complete_body, "token", token))
             |> json_response(403)
  end

  test "a bad setup token is refused before any work" do
    Setup.ensure_setup_token()

    assert %{"error" => %{"code" => "forbidden"}} =
             public_conn()
             |> post(~p"/api/v1/setup", Map.put(@complete_body, "token", "not-the-token"))
             |> json_response(403)

    refute Setup.completed?()
  end

  test "the per-IP rate limit is enforced" do
    Setup.ensure_setup_token()
    # A distinct TEST-NET-1 address (RFC 5737) so this test's budget
    # can never collide with the default-IP requests the other tests
    # in this module make.
    ip = {192, 0, 2, 77}
    body = Map.put(@complete_body, "token", "not-the-token")

    for _attempt <- 1..10 do
      assert public_conn(ip) |> post(~p"/api/v1/setup", body) |> json_response(403)
    end

    assert %{"error" => %{"code" => "rate_limited"}} =
             public_conn(ip) |> post(~p"/api/v1/setup", body) |> json_response(429)
  end

  test "malformed bodies burn rate-limit budget too" do
    # A token-less or non-string-token body must not be a free way
    # around the limiter: the budget is spent before the body is
    # inspected, so exactly the same ceiling applies.
    Setup.ensure_setup_token()
    ip = {192, 0, 2, 78}

    for _attempt <- 1..10 do
      assert public_conn(ip)
             |> post(~p"/api/v1/setup", %{"token" => 12_345})
             |> json_response(400)
    end

    assert %{"error" => %{"code" => "rate_limited"}} =
             public_conn(ip)
             |> post(~p"/api/v1/setup", %{"token" => 12_345})
             |> json_response(429)
  end

  defp public_conn, do: public_conn({127, 0, 0, 1})

  defp public_conn(ip) do
    build_conn()
    |> Map.put(:remote_ip, ip)
    |> put_req_header("accept", "application/json")
  end
end
