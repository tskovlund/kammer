defmodule KammerWeb.Api.StepUpTest do
  @moduledoc """
  Step-up re-auth over the API (issue #294, ADR 0029): the passkey and
  email-link step-up ceremonies, and the gate they open — every
  credential-changing endpoint answers 401 `step_up_required` until
  the calling device token has freshly re-asserted a root of trust.
  """

  use KammerWeb.ConnCase, async: true

  import Ecto.Query
  import Kammer.AccountsFixtures
  import Kammer.WebauthnHelper
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions
  import Swoosh.TestAssertions

  alias Kammer.Accounts
  alias Kammer.Accounts.UserToken
  alias Kammer.Repo

  setup do
    user = user_fixture()
    bearer = Accounts.create_device_token(user, "Min telefon")
    %{user: user, bearer: bearer, conn: bearer_conn(bearer)}
  end

  describe "POST /api/v1/auth/step-up/passkey/challenge" do
    test "scopes allow_credentials to the caller's own passkeys", %{conn: conn, user: user} do
      %{credential_id: own_id} = register_passkey!(user)
      register_passkey!(user_fixture())

      body =
        conn
        |> post(~p"/api/v1/auth/step-up/passkey/challenge")
        |> tap(&assert_operation_response(&1, "step_up_passkey_challenge"))
        |> json_response(200)

      assert %{"challenge" => _, "rp_id" => _, "challenge_token" => _} = body["data"]

      assert body["data"]["allow_credentials"] == [
               Base.url_encode64(own_id, padding: false)
             ]
    end
  end

  describe "POST /api/v1/auth/step-up/passkey/verify" do
    test "a valid assertion steps up the calling row only and mints nothing", %{
      conn: conn,
      user: user,
      bearer: bearer
    } do
      passkey = register_passkey!(user)
      bystander_bearer = Accounts.create_device_token(user, "Gammel tablet")
      rows_before = user_token_count(user)

      %{"data" => challenge} =
        conn |> post(~p"/api/v1/auth/step-up/passkey/challenge") |> json_response(200)

      body =
        conn
        |> verify_step_up(challenge, assertion_for(challenge, passkey))
        |> tap(&assert_operation_response(&1, "step_up_passkey_verify"))
        |> json_response(200)

      # Stepped up, nothing minted: no device_token in the answer, no
      # new token rows, and only the CALLING credential is elevated.
      assert body == %{"status" => "stepped_up"}
      assert user_token_count(user) == rows_before
      assert Accounts.device_stepped_up?(Accounts.get_device_token(bearer))
      refute Accounts.device_stepped_up?(Accounts.get_device_token(bystander_bearer))

      # The gate opens: enrollment's challenge now answers 200.
      conn |> post(~p"/api/v1/me/passkeys/challenge") |> json_response(200)
    end

    test "another user's valid credential is the neutral 422 and elevates nothing", %{
      conn: conn,
      bearer: bearer
    } do
      other_passkey = register_passkey!(user_fixture())

      %{"data" => challenge} =
        conn |> post(~p"/api/v1/auth/step-up/passkey/challenge") |> json_response(200)

      # The assertion itself verifies (real credential, right
      # challenge) — only the ownership check can refuse it, and the
      # answer must be indistinguishable from any other failure.
      assert %{"error" => %{"code" => "invalid_params"}} =
               conn
               |> verify_step_up(challenge, assertion_for(challenge, other_passkey))
               |> json_response(422)

      refute Accounts.device_stepped_up?(Accounts.get_device_token(bearer))
    end

    test "a sign-in challenge token never verifies as a step-up one (distinct salts)", %{
      conn: conn,
      user: user,
      bearer: bearer
    } do
      passkey = register_passkey!(user)

      # A full, valid ceremony against the SIGN-IN challenge — only the
      # token's salt is wrong, and that alone must sink it.
      sign_in_challenge =
        conn |> post(~p"/api/v1/auth/passkey/challenge") |> json_response(200)

      assert %{"error" => %{"code" => "invalid_params"}} =
               conn
               |> verify_step_up(sign_in_challenge, assertion_for(sign_in_challenge, passkey))
               |> json_response(422)

      refute Accounts.device_stepped_up?(Accounts.get_device_token(bearer))
    end
  end

  describe "POST /api/v1/auth/step-up/request-link + /confirm" do
    test "the emailed link steps up the requesting device via the public confirm", %{
      conn: conn,
      user: user,
      bearer: bearer
    } do
      drain_delivered_emails()

      conn
      |> post(~p"/api/v1/auth/step-up/request-link")
      |> tap(&assert_operation_response(&1, "step_up_request_link"))
      |> json_response(200)

      # To the account's OWN address, deep-linking into the PWA.
      assert_email_sent(fn email ->
        with [{"", to}] when to == user.email <- email.to,
             [token] <-
               Regex.run(~r{/step-up/([\w-]+)}, email.text_body, capture: :all_but_first) do
          send(self(), {:step_up_token, token})
          true
        else
          _no_match -> false
        end
      end)

      assert_received {:step_up_token, token}
      refute Accounts.device_stepped_up?(Accounts.get_device_token(bearer))

      # Confirm carries NO Authorization header — the link may open in
      # a different browser than the requesting app.
      %{"status" => "stepped_up"} =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post(~p"/api/v1/auth/step-up/confirm", %{"token" => token})
        |> tap(&assert_operation_response(&1, "step_up_confirm"))
        |> json_response(200)

      assert Accounts.device_stepped_up?(Accounts.get_device_token(bearer))

      # Single-use: the replay and plain garbage are one neutral 404.
      build_conn()
      |> put_req_header("accept", "application/json")
      |> post(~p"/api/v1/auth/step-up/confirm", %{"token" => token})
      |> json_response(404)

      build_conn()
      |> put_req_header("accept", "application/json")
      |> post(~p"/api/v1/auth/step-up/confirm", %{"token" => "garbage"})
      |> json_response(404)
    end

    test "shares the magic-link email budget", %{conn: conn} do
      # 3 per address per 15 minutes, and the fixture's own sign-in
      # email already spent the first — sharing means sharing.
      for _request <- 1..2 do
        conn |> post(~p"/api/v1/auth/step-up/request-link") |> json_response(200)
      end

      assert %{"error" => %{"code" => "rate_limited"}} =
               conn |> post(~p"/api/v1/auth/step-up/request-link") |> json_response(429)
    end
  end

  describe "the step-up gate (#294)" do
    test "every gated endpoint answers 401 step_up_required until stepped up", %{
      conn: conn,
      user: user
    } do
      %{"data" => [%{"id" => own_device_id}]} =
        conn |> get(~p"/api/v1/me/devices") |> json_response(200)

      other_bearer = Accounts.create_device_token(user, "Gammel tablet")
      other_id = Accounts.get_device_token(other_bearer).id

      gated_requests = [
        post(conn, ~p"/api/v1/me/passkeys/challenge"),
        post(conn, ~p"/api/v1/me/passkeys", %{"challenge_token" => "x"}),
        delete(conn, ~p"/api/v1/me/passkeys/#{Ecto.UUID.generate()}"),
        post(conn, ~p"/api/v1/me/email-change", %{"email" => "ny@example.org"}),
        delete(conn, ~p"/api/v1/me/devices/#{other_id}")
      ]

      for refused <- gated_requests do
        assert %{"error" => %{"code" => "step_up_required"}} = json_response(refused, 401)
      end

      # Nothing behind the gate happened.
      assert Accounts.get_device_token(other_bearer)

      # Self-revoke is sign-out, not a credential change — ungated.
      conn |> delete(~p"/api/v1/me/devices/#{own_device_id}") |> json_response(200)
    end

    test "a stale step-up is refused exactly like none at all", %{user: user} do
      conn = api_conn(user, stepped_up: true)
      backdate_step_up(user, Kammer.Config.step_up_validity_minutes() + 1)

      assert %{"error" => %{"code" => "step_up_required"}} =
               conn |> post(~p"/api/v1/me/passkeys/challenge") |> json_response(401)
    end

    test "a fresh step-up lets a foreign device be revoked", %{user: user} do
      conn = api_conn(user, stepped_up: true)
      other_bearer = Accounts.create_device_token(user, "Stjålet telefon")
      other_id = Accounts.get_device_token(other_bearer).id

      %{"status" => "revoked"} =
        conn |> delete(~p"/api/v1/me/devices/#{other_id}") |> json_response(200)

      refute Accounts.get_device_token(other_bearer)
    end
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

    ceremony
  end

  # The assertion a browser would produce for a challenge response,
  # signed with the given registered credential's key pair.
  defp assertion_for(challenge_body, %{credential_id: credential_id, key_pair: key_pair}) do
    client_challenge = %{
      bytes: Base.url_decode64!(challenge_body["challenge"], padding: false),
      rp_id: challenge_body["rp_id"]
    }

    authentication_ceremony(client_challenge, KammerWeb.Endpoint.url(), credential_id, key_pair)
  end

  defp verify_step_up(conn, challenge_body, assertion) do
    post(conn, ~p"/api/v1/auth/step-up/passkey/verify", %{
      "challenge_token" => challenge_body["challenge_token"],
      "credential_id" => Base.url_encode64(assertion.credential_id, padding: false),
      "authenticator_data" => Base.url_encode64(assertion.authenticator_data, padding: false),
      "signature" => Base.url_encode64(assertion.signature, padding: false),
      "client_data_json" => Base.url_encode64(assertion.client_data_json, padding: false)
    })
  end

  defp user_token_count(user) do
    Repo.aggregate(from(t in UserToken, where: t.user_id == ^user.id), :count)
  end

  defp backdate_step_up(user, minutes_ago) do
    stale = DateTime.add(DateTime.utc_now(:second), -minutes_ago, :minute)

    Repo.update_all(
      from(t in UserToken, where: t.user_id == ^user.id and t.context == "api-device"),
      set: [stepped_up_at: stale]
    )
  end

  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end
end
