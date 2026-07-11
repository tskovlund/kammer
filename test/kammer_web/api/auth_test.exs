defmodule KammerWeb.Api.AuthTest do
  @moduledoc """
  The API auth lifecycle (ADR 0014): request link → exchange for device
  token → authenticated request → revoke. Same passwordless flow as the
  web, same neutral responses, same revocability.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.WebauthnHelper
  import OpenApiSpex.TestAssertions
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

      # web_push reflects real server config; the VAPID public key the
      # PWA needs for PushManager.subscribe rides alongside it (#251),
      # and is null exactly when push isn't configured. The test env has
      # no VAPID keys, so both are the disabled shape.
      assert body["features"]["web_push"] == false
      assert %{"vapid_public_key" => nil} = body["features"]

      # mix.exs is the single source of truth (issue #204) — the API
      # must report exactly what the project was built from — and the
      # min-client floor is present-but-null until a release sets it.
      assert body["version"] == Mix.Project.config()[:version]
      assert %{"min_client_version" => nil} = body
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
        |> tap(&assert_operation_response(&1, "auth_register"))
        |> json_response(201)

      assert body["status"] == "confirmation_sent"
      assert body["user"]["email"] == "new-signup@example.org"
      assert Accounts.get_user_by_email("new-signup@example.org")

      # ADR 0024: the confirmation email deep-links into the
      # instance-served PWA and carries a sign-in code.
      assert_email_sent(fn email ->
        email.to == [{"", "new-signup@example.org"}] and
          email.text_body =~ ~r{/app/sign-in/[\w-]+} and
          email.text_body =~ ~r/sign-in code in the app:/
      end)
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
      |> tap(&assert_operation_response(&1, "auth_request_link"))
      |> json_response(200)

      # ADR 0024: API-initiated sign-in emails deep-link into the
      # instance-served PWA, not the LiveView landing page.
      assert_email_sent(fn email ->
        case Regex.run(~r{/app/sign-in/([\w-]+)}, email.text_body, capture: :all_but_first) do
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
        |> tap(&assert_operation_response(&1, "auth_exchange"))
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
      |> tap(&assert_operation_response(&1, "auth_revoke"))
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

    test "the sign-in email also carries a code that exchanges for a device token", %{conn: conn} do
      user = user_fixture()
      drain_delivered_emails()

      conn
      |> json_conn()
      |> post(~p"/api/v1/auth/request-link", %{"email" => user.email})
      |> json_response(200)

      assert_email_sent(fn email ->
        case Regex.run(~r/sign-in code in the app:\n\n([0-9A-Z]{8})/, email.text_body,
               capture: :all_but_first
             ) do
          [code] ->
            send(self(), {:sign_in_code, code})
            true

          nil ->
            false
        end
      end)

      assert_received {:sign_in_code, code}

      %{"device_token" => device_token, "user" => user_body} =
        build_conn()
        |> json_conn()
        |> post(~p"/api/v1/auth/exchange", %{
          "email" => user.email,
          "code" => code,
          "device_name" => "Other device"
        })
        |> tap(&assert_operation_response(&1, "auth_exchange"))
        |> json_response(200)

      assert user_body["email"] == user.email
      assert Accounts.get_user_by_device_token(device_token).id == user.id

      # The code was single-use.
      assert %{"error" => %{"code" => "unauthorized"}} =
               build_conn()
               |> json_conn()
               |> post(~p"/api/v1/auth/exchange", %{"email" => user.email, "code" => code})
               |> json_response(401)
    end

    test "a wrong code and an unknown email are indistinguishable", %{conn: conn} do
      user = user_fixture()

      wrong_code_body =
        conn
        |> json_conn()
        |> post(~p"/api/v1/auth/exchange", %{"email" => user.email, "code" => "WRONGWRO"})
        |> json_response(401)

      unknown_email_body =
        build_conn()
        |> json_conn()
        |> post(~p"/api/v1/auth/exchange", %{
          "email" => "nobody-here@example.org",
          "code" => "WRONGWRO"
        })
        |> json_response(401)

      assert wrong_code_body == unknown_email_body
    end

    test "repeated wrong codes trip the rate limit", %{conn: conn} do
      user = user_fixture()

      for _attempt <- 1..5 do
        conn
        |> json_conn()
        |> post(~p"/api/v1/auth/exchange", %{"email" => user.email, "code" => "WRONGWRO"})
        |> json_response(401)
      end

      assert %{"error" => %{"code" => "rate_limited"}} =
               build_conn()
               |> json_conn()
               |> post(~p"/api/v1/auth/exchange", %{"email" => user.email, "code" => "WRONGWRO"})
               |> json_response(429)
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

  describe "passkey sign-in (issue #177, ADR 0018)" do
    setup do
      user = user_fixture()
      origin = KammerWeb.Endpoint.url()
      challenge = Accounts.new_passkey_registration_challenge(user, origin)
      ceremony = registration_ceremony(challenge, origin)

      {:ok, _passkey} =
        Accounts.register_passkey(
          user,
          ceremony.attestation_object,
          ceremony.client_data_json,
          challenge
        )

      %{
        user: user,
        origin: origin,
        credential_id: ceremony.credential_id,
        key_pair: ceremony.key_pair
      }
    end

    test "challenge → assertion → device token", %{conn: conn} = context do
      challenge_body =
        conn
        |> json_conn()
        |> post(~p"/api/v1/auth/passkey/challenge")
        |> tap(&assert_operation_response(&1, "auth_passkey_challenge"))
        |> json_response(200)

      assert %{
               "challenge" => _challenge,
               "rp_id" => _rp_id,
               "challenge_token" => _challenge_token
             } = challenge_body

      %{"device_token" => device_token, "user" => user_body} =
        build_conn()
        |> json_conn()
        |> post(~p"/api/v1/auth/passkey/verify", verify_params(challenge_body, context))
        |> tap(&assert_operation_response(&1, "auth_passkey_verify"))
        |> json_response(200)

      assert user_body["id"] == context.user.id
      assert Accounts.get_user_by_device_token(device_token).id == context.user.id
    end

    test "an assertion signed with the wrong key gets a neutral 401", %{conn: conn} = context do
      challenge_body =
        conn
        |> json_conn()
        |> post(~p"/api/v1/auth/passkey/challenge")
        |> json_response(200)

      params = verify_params(challenge_body, %{context | key_pair: generate_key_pair()})

      assert %{"error" => %{"code" => "unauthorized"}} =
               build_conn()
               |> json_conn()
               |> post(~p"/api/v1/auth/passkey/verify", params)
               |> json_response(401)
    end

    test "a tampered challenge token gets a neutral 401", %{conn: conn} = context do
      challenge_body =
        conn
        |> json_conn()
        |> post(~p"/api/v1/auth/passkey/challenge")
        |> json_response(200)

      params =
        challenge_body
        |> verify_params(context)
        |> Map.put("challenge_token", "tampered-token")

      assert %{"error" => %{"code" => "unauthorized"}} =
               build_conn()
               |> json_conn()
               |> post(~p"/api/v1/auth/passkey/verify", params)
               |> json_response(401)
    end

    test "verify without a challenge token is a bad request", %{conn: conn} do
      assert %{"error" => %{"code" => "bad_request"}} =
               conn
               |> json_conn()
               |> post(~p"/api/v1/auth/passkey/verify", %{"credential_id" => "abc"})
               |> json_response(400)
    end
  end

  # Builds the JSON verify payload a browser-side client would send
  # for the assertion options the challenge endpoint returned.
  defp verify_params(challenge_body, context) do
    client_challenge = %{
      bytes: Base.url_decode64!(challenge_body["challenge"], padding: false),
      rp_id: challenge_body["rp_id"]
    }

    assertion =
      authentication_ceremony(
        client_challenge,
        context.origin,
        context.credential_id,
        context.key_pair
      )

    %{
      "challenge_token" => challenge_body["challenge_token"],
      "credential_id" => Base.url_encode64(assertion.credential_id, padding: false),
      "authenticator_data" => Base.url_encode64(assertion.authenticator_data, padding: false),
      "signature" => Base.url_encode64(assertion.signature, padding: false),
      "client_data_json" => Base.url_encode64(assertion.client_data_json, padding: false),
      "device_name" => "Passkey device"
    }
  end
end
