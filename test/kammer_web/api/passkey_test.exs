defmodule KammerWeb.Api.PasskeyTest do
  @moduledoc """
  Passkey enrollment over the API (issue #260 port 5b, ADR 0018): the
  authenticated challenge → attestation → store ceremony, plus listing
  and deletion. Exercised against the real Wax verification path via
  hand-crafted ceremonies (`WebauthnHelper`), the same code a browser's
  `navigator.credentials.create` feeds.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.WebauthnHelper
  import OpenApiSpex.TestAssertions

  alias Kammer.Accounts

  setup do
    user = user_fixture()
    %{user: user, conn: KammerWeb.ApiHelpers.api_conn(user)}
  end

  describe "POST /api/v1/me/passkeys/challenge" do
    test "returns registration options for the caller", %{conn: conn, user: user} do
      body =
        conn
        |> post(~p"/api/v1/me/passkeys/challenge")
        |> tap(&assert_operation_response(&1, "passkeys_challenge"))
        |> json_response(200)

      assert %{
               "challenge" => _challenge,
               "rp_id" => _rp_id,
               "challenge_token" => _token,
               "user_name" => user_name,
               "user_display_name" => display_name,
               "exclude_credentials" => []
             } = body["data"]

      assert user_name == user.email
      assert display_name == user.display_name
      assert body["data"]["user_id"] == Base.url_encode64(user.id, padding: false)
    end

    test "excludes an already-registered credential", %{conn: conn, user: user} do
      register_passkey!(user)
      [passkey] = Accounts.list_passkeys(user)

      body =
        conn
        |> post(~p"/api/v1/me/passkeys/challenge")
        |> json_response(200)

      assert body["data"]["exclude_credentials"] == [
               Base.url_encode64(passkey.credential_id, padding: false)
             ]
    end
  end

  describe "POST /api/v1/me/passkeys" do
    test "stores a credential from a valid ceremony and returns it", %{conn: conn, user: user} do
      %{"data" => challenge} =
        conn
        |> post(~p"/api/v1/me/passkeys/challenge")
        |> json_response(200)

      ceremony = ceremony_for(challenge)

      body =
        conn
        |> post(~p"/api/v1/me/passkeys", %{
          "challenge_token" => challenge["challenge_token"],
          "attestation_object" => Base.url_encode64(ceremony.attestation_object, padding: false),
          "client_data_json" => Base.url_encode64(ceremony.client_data_json, padding: false),
          "nickname" => "My laptop"
        })
        |> tap(&assert_operation_response(&1, "passkeys_create"))
        |> json_response(201)

      assert body["data"]["nickname"] == "My laptop"
      assert [%{nickname: "My laptop", credential_id: id}] = Accounts.list_passkeys(user)
      assert id == ceremony.credential_id
      refute Map.has_key?(body["data"], "credential_id")
    end

    test "a blank nickname is stored as nil, not an empty string", %{conn: conn, user: user} do
      %{"data" => challenge} =
        conn |> post(~p"/api/v1/me/passkeys/challenge") |> json_response(200)

      ceremony = ceremony_for(challenge)

      body =
        conn
        |> post(~p"/api/v1/me/passkeys", %{
          "challenge_token" => challenge["challenge_token"],
          "attestation_object" => Base.url_encode64(ceremony.attestation_object, padding: false),
          "client_data_json" => Base.url_encode64(ceremony.client_data_json, padding: false),
          "nickname" => "   "
        })
        |> json_response(201)

      assert body["data"]["nickname"] == nil
      assert [%{nickname: nil}] = Accounts.list_passkeys(user)
    end

    test "a duplicate credential is the same neutral 422 and stores no second copy", %{
      conn: conn,
      user: user
    } do
      %{"data" => first_challenge} =
        conn |> post(~p"/api/v1/me/passkeys/challenge") |> json_response(200)

      first = ceremony_for(first_challenge)
      conn |> create_passkey(first_challenge, first) |> json_response(201)

      # A client ignoring exclude_credentials re-submits the same credential
      # (same id + key) against a fresh challenge — the instance-wide unique
      # constraint rejects it, and it collapses to the same neutral 422.
      %{"data" => second_challenge} =
        conn |> post(~p"/api/v1/me/passkeys/challenge") |> json_response(200)

      dup =
        ceremony_for(second_challenge,
          credential_id: first.credential_id,
          key_pair: first.key_pair
        )

      body = conn |> create_passkey(second_challenge, dup) |> json_response(422)
      assert body["error"]["code"] == "invalid_params"
      assert [_only_one] = Accounts.list_passkeys(user)
    end

    test "an over-long nickname is truncated, never a 500", %{conn: conn, user: user} do
      %{"data" => challenge} =
        conn |> post(~p"/api/v1/me/passkeys/challenge") |> json_response(200)

      ceremony = ceremony_for(challenge)

      # One base char + three combining marks = 1 grapheme but 4 codepoints;
      # 150 of them is 600 codepoints. A grapheme-based cap would leave >255
      # codepoints and overflow the varchar(255) column (Postgres raises,
      # 500). Codepoint truncation keeps it under the limit.
      grapheme = "a" <> <<0x0301::utf8>> <> <<0x0302::utf8>> <> <<0x0303::utf8>>
      long = String.duplicate(grapheme, 150)

      conn
      |> post(~p"/api/v1/me/passkeys", %{
        "challenge_token" => challenge["challenge_token"],
        "attestation_object" => Base.url_encode64(ceremony.attestation_object, padding: false),
        "client_data_json" => Base.url_encode64(ceremony.client_data_json, padding: false),
        "nickname" => long
      })
      |> json_response(201)

      assert [%{nickname: stored}] = Accounts.list_passkeys(user)
      assert length(String.codepoints(stored)) <= 100
    end

    test "a valid token with a structurally-bogus attestation is a neutral 422, not a 500", %{
      conn: conn,
      user: user
    } do
      %{"data" => challenge} =
        conn |> post(~p"/api/v1/me/passkeys/challenge") |> json_response(200)

      ceremony = ceremony_for(challenge)

      # A real client_data_json but an attestation that is valid base64url +
      # valid CBOR yet not the map Wax expects (an empty CBOR map). This used
      # to raise a MatchError inside Wax.register and escape as a 500,
      # breaking the neutral-failure contract; it must collapse to the same
      # 422 as every other failure.
      body =
        conn
        |> post(~p"/api/v1/me/passkeys", %{
          "challenge_token" => challenge["challenge_token"],
          "attestation_object" => Base.url_encode64(<<0xA0>>, padding: false),
          "client_data_json" => Base.url_encode64(ceremony.client_data_json, padding: false)
        })
        |> json_response(422)

      assert body["error"]["code"] == "invalid_params"
      assert Accounts.list_passkeys(user) == []
    end

    test "a tampered challenge token is a neutral 422 that stores nothing", %{
      conn: conn,
      user: user
    } do
      %{"data" => challenge} =
        conn
        |> post(~p"/api/v1/me/passkeys/challenge")
        |> json_response(200)

      ceremony = ceremony_for(challenge)

      body =
        conn
        |> post(~p"/api/v1/me/passkeys", %{
          "challenge_token" => "tampered-token",
          "attestation_object" => Base.url_encode64(ceremony.attestation_object, padding: false),
          "client_data_json" => Base.url_encode64(ceremony.client_data_json, padding: false)
        })
        |> json_response(422)

      assert body["error"]["code"] == "invalid_params"
      assert Accounts.list_passkeys(user) == []
    end

    test "an absent challenge token is the same neutral 422", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_params"}} =
               conn
               |> post(~p"/api/v1/me/passkeys", %{"attestation_object" => "abc"})
               |> json_response(422)
    end
  end

  describe "GET /api/v1/me/passkeys" do
    test "lists the caller's passkeys and not another user's", %{conn: conn, user: user} do
      register_passkey!(user)
      register_passkey!(user_fixture())

      body =
        conn
        |> get(~p"/api/v1/me/passkeys")
        |> tap(&assert_operation_response(&1, "passkeys_index"))
        |> json_response(200)

      [own] = Accounts.list_passkeys(user)
      assert [%{"id" => id}] = body["data"]
      assert id == own.id
    end
  end

  describe "DELETE /api/v1/me/passkeys/{passkey_id}" do
    test "removes the caller's own passkey", %{conn: conn, user: user} do
      register_passkey!(user)
      [passkey] = Accounts.list_passkeys(user)

      assert %{"status" => "revoked"} =
               conn
               |> delete(~p"/api/v1/me/passkeys/#{passkey.id}")
               |> tap(&assert_operation_response(&1, "passkeys_delete"))
               |> json_response(200)

      assert Accounts.list_passkeys(user) == []
    end

    test "a malformed id is the same idempotent 200, never a cast error", %{conn: conn} do
      assert %{"status" => "revoked"} =
               conn
               |> delete(~p"/api/v1/me/passkeys/not-a-uuid")
               |> json_response(200)
    end

    test "cannot delete another user's passkey", %{conn: conn} do
      other = user_fixture()
      register_passkey!(other)
      [passkey] = Accounts.list_passkeys(other)

      assert %{"status" => "revoked"} =
               conn
               |> delete(~p"/api/v1/me/passkeys/#{passkey.id}")
               |> json_response(200)

      # Scoped to the caller: the other user's passkey is untouched.
      assert [_still_there] = Accounts.list_passkeys(other)
    end
  end

  # Builds the ceremony a browser would produce for a challenge response,
  # decoding the origin and challenge back out of it exactly as a client
  # would before calling navigator.credentials.create.
  defp ceremony_for(challenge_body, opts \\ []) do
    client_challenge = %{
      bytes: Base.url_decode64!(challenge_body["challenge"], padding: false),
      rp_id: challenge_body["rp_id"]
    }

    registration_ceremony(client_challenge, KammerWeb.Endpoint.url(), opts)
  end

  defp create_passkey(conn, challenge, ceremony) do
    post(conn, ~p"/api/v1/me/passkeys", %{
      "challenge_token" => challenge["challenge_token"],
      "attestation_object" => Base.url_encode64(ceremony.attestation_object, padding: false),
      "client_data_json" => Base.url_encode64(ceremony.client_data_json, padding: false)
    })
  end

  defp register_passkey!(user) do
    challenge = Accounts.new_passkey_registration_challenge(user, KammerWeb.Endpoint.url())
    ceremony = registration_ceremony(challenge, KammerWeb.Endpoint.url())

    {:ok, _passkey} =
      Accounts.register_passkey(
        user,
        ceremony.attestation_object,
        ceremony.client_data_json,
        challenge
      )
  end
end
