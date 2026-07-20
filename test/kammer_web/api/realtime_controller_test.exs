defmodule KammerWeb.Api.RealtimeControllerTest do
  @moduledoc """
  The realtime-token mint endpoint (issue #175): an authenticated device
  gets a short-lived socket token bound to itself; an anonymous caller gets
  a 401. The device token authenticates via the header only — it is never
  echoed back and never rides the socket URL.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Accounts.UserToken
  alias Kammer.Repo
  alias KammerWeb.Api.SocketToken

  test "mints a socket token bound to the caller and their device token" do
    user = user_fixture()
    # Build the device token inline (rather than via api_conn/1) so the test
    # can pin the socket token's device id to *this* row.
    {token, user_token} = UserToken.build_device_token(user, "test device")
    device = Repo.insert!(user_token)

    body =
      token
      |> bearer_conn()
      |> post(~p"/api/v1/realtime/token")
      |> tap(&assert_operation_response(&1, "realtime_token"))
      |> json_response(200)

    assert body["data"]["expires_in"] == SocketToken.max_age_seconds()

    # The token verifies to this user and *this device row* — the exact
    # (user_id, device_token_id) pair UserSocket.connect binds on, not merely
    # some binary id.
    assert {:ok, user_id, device_id} = SocketToken.verify(body["data"]["token"])
    assert user_id == user.id
    assert device_id == device.id
  end

  test "requires a device token" do
    assert %{"error" => %{"code" => "unauthorized"}} =
             build_conn()
             |> put_req_header("accept", "application/json")
             |> post(~p"/api/v1/realtime/token")
             |> json_response(401)
  end
end
