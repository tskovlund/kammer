defmodule KammerWeb.UserLive.DevicesTest do
  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.WebauthnHelper
  import Phoenix.LiveViewTest

  alias Kammer.Accounts

  describe "Devices page" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "lists the current session marked as this device", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/settings/devices")

      assert html =~ "Devices"
      assert html =~ "This device"
    end

    test "revokes another session", %{conn: conn, user: user} do
      other_token = Accounts.generate_user_session_token(user, "OtherBrowser/1.0")

      {:ok, lv, _html} = live(conn, ~p"/users/settings/devices")

      other_session =
        Enum.find(Accounts.list_user_sessions(user), fn session ->
          session.token == other_token
        end)

      lv
      |> element(~s(button[phx-value-id="#{other_session.id}"]))
      |> render_click()

      refute Accounts.get_user_by_session_token(other_token)
    end

    test "redirects if user is not logged in" do
      conn = build_conn()
      assert {:error, redirect} = live(conn, ~p"/users/settings/devices")
      assert {:redirect, %{to: path}} = redirect
      assert path == ~p"/users/log-in"
    end
  end

  describe "Passkeys section" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "registering with a valid ceremony adds it to the list", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/settings/devices")

      challenge = fake_challenge_from_html(html, "passkey-register-button")
      ceremony = registration_ceremony(challenge, KammerWeb.Endpoint.url())

      html =
        lv
        |> render_hook("passkey_attestation", %{
          "attestation_object" => Base.url_encode64(ceremony.attestation_object, padding: false),
          "client_data_json" => Base.url_encode64(ceremony.client_data_json, padding: false)
        })

      assert html =~ "Passkey added"
      refute html =~ "No passkeys yet"
    end

    test "a tampered ceremony is refused", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/settings/devices")

      challenge = fake_challenge_from_html(html, "passkey-register-button")
      ceremony = registration_ceremony(challenge, "https://not-this-instance.example")

      html =
        lv
        |> render_hook("passkey_attestation", %{
          "attestation_object" => Base.url_encode64(ceremony.attestation_object, padding: false),
          "client_data_json" => Base.url_encode64(ceremony.client_data_json, padding: false)
        })

      assert html =~ "Couldn&#39;t add that passkey"
      assert html =~ "No passkeys yet"
    end

    test "removing a passkey", %{conn: conn, user: user} do
      challenge = Accounts.new_passkey_registration_challenge(user, KammerWeb.Endpoint.url())
      ceremony = registration_ceremony(challenge, KammerWeb.Endpoint.url())

      {:ok, passkey} =
        Accounts.register_passkey(
          user,
          ceremony.attestation_object,
          ceremony.client_data_json,
          challenge,
          "My key"
        )

      {:ok, lv, html} = live(conn, ~p"/users/settings/devices")
      assert html =~ "My key"

      lv
      |> element(~s(button[phx-value-id="#{passkey.id}"]))
      |> render_click()

      assert Accounts.list_passkeys(user) == []
    end
  end

  # The LiveView keeps its `Wax.Challenge` in socket state, out of test
  # reach; reconstruct an equivalent one from what it rendered so a
  # hand-crafted ceremony (`WebauthnHelper`) verifies against it.
  defp fake_challenge_from_html(html, button_id) do
    %{"challenge" => challenge, "rp_id" => rp_id} =
      Regex.named_captures(
        ~r/id="#{button_id}"[\s\S]*?data-challenge="(?<challenge>[^"]+)"[\s\S]*?data-rp-id="(?<rp_id>[^"]+)"/,
        html
      )

    Wax.Challenge.new(
      type: :attestation,
      bytes: Base.url_decode64!(challenge, padding: false),
      origin: KammerWeb.Endpoint.url(),
      rp_id: rp_id
    )
  end
end
