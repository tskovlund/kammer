defmodule KammerWeb.Api.AuthTest do
  @moduledoc """
  The API auth lifecycle (ADR 0014): request link → exchange for device
  token → authenticated request → revoke. Same passwordless flow as the
  web, same neutral responses, same revocability.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Swoosh.TestAssertions

  alias Kammer.Accounts

  defp json_conn(conn), do: put_req_header(conn, "accept", "application/json")

  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end

  describe "GET /api/v1/instance" do
    test "answers without authentication", %{conn: conn} do
      body =
        conn
        |> json_conn()
        |> get(~p"/api/v1/instance")
        |> json_response(200)

      assert body["api_versions"] == ["v1"]
      assert body["features"]["registration"] == "open"
    end
  end

  describe "POST /api/v1/auth/register" do
    test "creates an account and sends a confirmation magic link", %{conn: conn} do
      body =
        conn
        |> json_conn()
        |> post(~p"/api/v1/auth/register", %{
          "email" => "new-signup@example.org",
          "display_name" => "New Signup"
        })
        |> json_response(201)

      assert body["status"] == "confirmation_sent"
      assert body["user"]["email"] == "new-signup@example.org"
      assert Accounts.get_user_by_email("new-signup@example.org")

      assert_email_sent(fn email -> email.to == [{"", "new-signup@example.org"}] end)
    end

    test "rejects a duplicate email with the standard validation envelope", %{conn: conn} do
      user = user_fixture()

      body =
        conn
        |> json_conn()
        |> post(~p"/api/v1/auth/register", %{
          "email" => user.email,
          "display_name" => "Someone Else"
        })
        |> json_response(422)

      assert body["error"]["code"] == "invalid_params"
      assert body["error"]["details"]["email"]
    end
  end

  describe "the device-token lifecycle" do
    test "request → exchange → use → revoke", %{conn: conn} do
      user = user_fixture()
      drain_delivered_emails()

      conn
      |> json_conn()
      |> post(~p"/api/v1/auth/request-link", %{"email" => user.email})
      |> json_response(200)

      assert_email_sent(fn email ->
        case Regex.run(~r{users/log-in/([\w-]+)}, email.text_body, capture: :all_but_first) do
          [token] ->
            send(self(), {:magic_token, token})
            true

          nil ->
            false
        end
      end)

      assert_received {:magic_token, magic_token}

      %{"device_token" => device_token, "user" => user_body} =
        build_conn()
        |> json_conn()
        |> post(~p"/api/v1/auth/exchange", %{
          "magic_token" => magic_token,
          "device_name" => "Test suite"
        })
        |> json_response(200)

      assert user_body["email"] == user.email
      assert Accounts.get_user_by_device_token(device_token).id == user.id

      # The magic link was single-use.
      build_conn()
      |> json_conn()
      |> post(~p"/api/v1/auth/exchange", %{"magic_token" => magic_token})
      |> json_response(401)

      # Revoke kills the device token.
      # Revocation also severs any live socket for the device's user.
      KammerWeb.Endpoint.subscribe("api_user_socket:#{user_body["id"]}")

      build_conn()
      |> json_conn()
      |> put_req_header("authorization", "Bearer #{device_token}")
      |> delete(~p"/api/v1/auth/device-token")
      |> json_response(200)

      assert Accounts.get_user_by_device_token(device_token) == nil
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "unknown emails get the same neutral answer", %{conn: conn} do
      body =
        conn
        |> json_conn()
        |> post(~p"/api/v1/auth/request-link", %{"email" => "nobody@example.org"})
        |> json_response(200)

      assert body == %{"status" => "sent"}
      refute_email_sent()
    end

    test "authenticated routes refuse garbage and missing tokens", %{conn: conn} do
      assert %{"error" => %{"code" => "unauthorized"}} =
               conn
               |> json_conn()
               |> delete(~p"/api/v1/auth/device-token")
               |> json_response(401)

      assert %{"error" => %{"code" => "unauthorized"}} =
               build_conn()
               |> json_conn()
               |> put_req_header("authorization", "Bearer garbage")
               |> delete(~p"/api/v1/auth/device-token")
               |> json_response(401)
    end
  end
end
