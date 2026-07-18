defmodule KammerWeb.Api.AccountTest do
  @moduledoc """
  Account lifecycle over the API (issue #258, SPEC §12): the
  email-change request → confirm round-trip, typed-back-email account
  deletion, and the self-serve export — the API twins of the LiveView
  settings flows that disappear with the #187 cut.
  """

  use KammerWeb.ConnCase, async: true

  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions
  import Swoosh.TestAssertions

  alias Kammer.Accounts
  alias Kammer.AccountsFixtures

  # The user fixture's own sign-in email must not satisfy the
  # email-change assertion below — same idiom as the auth tests.
  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end

  describe "email change" do
    test "request emails the new address a PWA link; confirming flips the email and rotates the device token" do
      user = AccountsFixtures.user_fixture()
      device_token = Accounts.create_device_token(user, "Min telefon")
      # Initiation is step-up-gated (issue #294; the gate itself is
      # exercised in step_up_test.exs).
      Accounts.step_up_device(Accounts.get_device_token(device_token))
      drain_delivered_emails()

      device_token
      |> bearer_conn()
      |> post(~p"/api/v1/me/email-change", %{"email" => "ny-adresse@example.org"})
      |> tap(&assert_operation_response(&1, "email_change_request"))
      |> json_response(200)

      # The confirmation goes to the *new* address only (same semantics
      # as the web flow) and deep-links into the PWA (ADR 0024).
      assert_email_sent(fn email ->
        with [{"", "ny-adresse@example.org"}] <- email.to,
             [token] <-
               Regex.run(~r{/confirm-email/([\w-]+)}, email.text_body, capture: :all_but_first) do
          send(self(), {:change_token, token})
          true
        else
          _no_match -> false
        end
      end)

      assert_received {:change_token, token}

      # Nothing changed yet — the request alone is inert.
      assert Accounts.get_user_by_email(user.email)

      %{"data" => profile, "device_token" => fresh_token} =
        device_token
        |> bearer_conn()
        |> post(~p"/api/v1/me/email-change/confirm", %{"token" => token})
        |> tap(&assert_operation_response(&1, "email_change_confirm"))
        |> json_response(200)

      assert profile["email"] == "ny-adresse@example.org"
      refute Accounts.get_user_by_email(user.email)

      # The OLD address is told the change happened — the one signal a
      # hijacked account's real owner still receives (no sudo-mode
      # equivalent gates the API flow).
      assert_email_sent(fn email ->
        email.to == [{"", user.email}] and email.text_body =~ "ny-adresse@example.org"
      end)

      # Device tokens are bound to the address they were issued under,
      # so the old credential died with the change; the rotated one
      # carries the session forward under the same device name.
      device_token |> bearer_conn() |> get(~p"/api/v1/me") |> json_response(401)

      %{"data" => %{"email" => "ny-adresse@example.org"}} =
        fresh_token |> bearer_conn() |> get(~p"/api/v1/me") |> json_response(200)

      # Single use: replaying the consumed token gets the neutral 404.
      fresh_token
      |> bearer_conn()
      |> post(~p"/api/v1/me/email-change/confirm", %{"token" => token})
      |> json_response(404)
    end

    test "an invalid new address is refused with changeset details" do
      user = AccountsFixtures.user_fixture()

      %{"error" => %{"code" => "invalid_params", "details" => details}} =
        user
        |> api_conn(stepped_up: true)
        |> post(~p"/api/v1/me/email-change", %{"email" => "ikke-en-adresse"})
        |> json_response(422)

      assert details["email"]
    end

    test "repeated requests trip the per-user rate limit" do
      user = AccountsFixtures.user_fixture()

      for _request <- 1..5 do
        user
        |> api_conn(stepped_up: true)
        |> post(~p"/api/v1/me/email-change", %{"email" => "ny-adresse@example.org"})
        |> json_response(200)
      end

      assert %{"error" => %{"code" => "rate_limited"}} =
               user
               |> api_conn(stepped_up: true)
               |> post(~p"/api/v1/me/email-change", %{"email" => "ny-adresse@example.org"})
               |> json_response(429)
    end

    test "a taken-address 422 still spends budget, so it can't enumerate accounts unthrottled" do
      user = AccountsFixtures.user_fixture()
      taken = AccountsFixtures.user_fixture()

      # Every probe of an already-registered address answers 422 — but it
      # must still burn the limit, or the 422-vs-200 difference would be a
      # registered/unregistered oracle with no throttle (the step-up gate
      # narrows who can probe, not how fast). Five taken-address
      # probes exhaust the budget; the sixth is 429, not another 422.
      for _probe <- 1..5 do
        user
        |> api_conn(stepped_up: true)
        |> post(~p"/api/v1/me/email-change", %{"email" => taken.email})
        |> json_response(422)
      end

      assert %{"error" => %{"code" => "rate_limited"}} =
               user
               |> api_conn(stepped_up: true)
               |> post(~p"/api/v1/me/email-change", %{"email" => taken.email})
               |> json_response(429)
    end

    test "a confirm token is bound to its own account — another account can't consume it" do
      alice = AccountsFixtures.user_fixture()
      alice_device = Accounts.create_device_token(alice, "Alice-telefon")
      Accounts.step_up_device(Accounts.get_device_token(alice_device))
      bob = AccountsFixtures.user_fixture()
      bob_device = Accounts.create_device_token(bob, "Bob-telefon")
      drain_delivered_emails()

      alice_device
      |> bearer_conn()
      |> post(~p"/api/v1/me/email-change", %{"email" => "alice-ny@example.org"})
      |> json_response(200)

      assert_email_sent(fn email ->
        with [{"", "alice-ny@example.org"}] <- email.to,
             [token] <-
               Regex.run(~r{/confirm-email/([\w-]+)}, email.text_body, capture: :all_but_first) do
          send(self(), {:alice_token, token})
          true
        else
          _no_match -> false
        end
      end)

      assert_received {:alice_token, token}

      # Bob presenting Alice's token gets the neutral 404 and consumes
      # nothing — Alice can still confirm afterwards.
      bob_device
      |> bearer_conn()
      |> post(~p"/api/v1/me/email-change/confirm", %{"token" => token})
      |> json_response(404)

      assert %{"data" => %{"email" => "alice-ny@example.org"}} =
               alice_device
               |> bearer_conn()
               |> post(~p"/api/v1/me/email-change/confirm", %{"token" => token})
               |> json_response(200)
    end
  end

  describe "account deletion" do
    # Deletion is step-up-gated since #323 (the gate itself is
    # exercised in step_up_test.exs); these conns arrive stepped up,
    # pinning that the typed-back-email check still runs AFTER the
    # gate — both protections stack.
    test "a mismatched confirm_email is a 422 and deletes nothing" do
      user = AccountsFixtures.user_fixture()

      %{"error" => %{"code" => "invalid_params"}} =
        user
        |> api_conn(stepped_up: true)
        |> delete(~p"/api/v1/me", %{"confirm_email" => "forkert@example.org"})
        |> json_response(422)

      assert Accounts.get_user_by_email(user.email)
    end

    test "the typed-back email deletes the account, revokes credentials, severs sockets" do
      user = AccountsFixtures.user_fixture()
      token = Accounts.create_device_token(user, "Min telefon")
      Accounts.step_up_device(Accounts.get_device_token(token))
      KammerWeb.Endpoint.subscribe("api_user_socket:#{user.id}")

      %{"status" => "deleted"} =
        token
        |> bearer_conn()
        |> delete(~p"/api/v1/me", %{"confirm_email" => user.email})
        |> tap(&assert_operation_response(&1, "me_delete"))
        |> json_response(200)

      refute Accounts.get_user_by_email(user.email)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      # The device token died with the cascade.
      token |> bearer_conn() |> get(~p"/api/v1/me") |> json_response(401)
    end
  end

  describe "export" do
    # Export is step-up-gated since #323 (the gate itself is exercised
    # in step_up_test.exs).
    test "streams the caller's export zip with their data.json inside" do
      user = AccountsFixtures.user_fixture()

      # The documented `application/zip` Accept isn't 406'd (#315).
      conn =
        user
        |> api_conn(stepped_up: true)
        |> put_req_header("accept", "application/zip")
        |> get(~p"/api/v1/me/export")

      assert response_content_type(conn, :zip)
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      # A personal data export must never sit in a shared cache (#315).
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]

      {:ok, entries} = :zip.unzip(response(conn, 200), [:memory])

      {_name, json} =
        Enum.find(entries, fn {name, _content} -> to_string(name) == "data.json" end)

      assert Jason.decode!(json)["profile"]["email"] == user.email
    end

    test "is throttled — a retry-loop can't hammer the in-memory zip build" do
      user = AccountsFixtures.user_fixture()

      for _request <- 1..3 do
        assert response_content_type(
                 user |> api_conn(stepped_up: true) |> get(~p"/api/v1/me/export"),
                 :zip
               )
      end

      assert %{"error" => %{"code" => "rate_limited"}} =
               user
               |> api_conn(stepped_up: true)
               |> get(~p"/api/v1/me/export")
               |> json_response(429)
    end
  end
end
