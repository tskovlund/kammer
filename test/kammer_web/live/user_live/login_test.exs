defmodule KammerWeb.UserLive.LoginTest do
  use KammerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kammer.AccountsFixtures
  import Kammer.WebauthnHelper

  alias Kammer.Accounts

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Sign in"
      assert html =~ "Create an account"
      assert html =~ "Email me a sign-in link"
    end
  end

  describe "user login - magic link" do
    test "sends magic link email when user exists", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"

      assert Kammer.Repo.get_by!(Kammer.Accounts.UserToken, user_id: user.id).context ==
               "login"
    end

    test "does not disclose if user is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"
    end
  end

  describe "user login - passkey" do
    test "a valid assertion signs the user in", %{conn: conn} do
      user = user_fixture()
      origin = KammerWeb.Endpoint.url()
      reg_challenge = Accounts.new_passkey_registration_challenge(user, origin)
      registration = registration_ceremony(reg_challenge, origin)

      {:ok, _passkey} =
        Accounts.register_passkey(
          user,
          registration.attestation_object,
          registration.client_data_json,
          reg_challenge
        )

      {:ok, lv, html} = live(conn, ~p"/users/log-in")
      auth_challenge = fake_authentication_challenge_from_html(html)

      assertion =
        authentication_ceremony(
          auth_challenge,
          origin,
          registration.credential_id,
          registration.key_pair
        )

      render_hook(lv, "passkey_assertion", %{
        "credential_id" => Base.url_encode64(assertion.credential_id, padding: false),
        "authenticator_data" => Base.url_encode64(assertion.authenticator_data, padding: false),
        "signature" => Base.url_encode64(assertion.signature, padding: false),
        "client_data_json" => Base.url_encode64(assertion.client_data_json, padding: false)
      })

      form = form(lv, "#login_form_passkey")
      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end

    test "an unknown credential shows an error and does not sign in", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")
      auth_challenge = fake_authentication_challenge_from_html(html)

      unknown_key_pair = generate_key_pair()

      assertion =
        authentication_ceremony(
          auth_challenge,
          KammerWeb.Endpoint.url(),
          :crypto.strong_rand_bytes(32),
          unknown_key_pair
        )

      html =
        render_hook(lv, "passkey_assertion", %{
          "credential_id" => Base.url_encode64(assertion.credential_id, padding: false),
          "authenticator_data" => Base.url_encode64(assertion.authenticator_data, padding: false),
          "signature" => Base.url_encode64(assertion.signature, padding: false),
          "client_data_json" => Base.url_encode64(assertion.client_data_json, padding: false)
        })

      assert html =~ "didn&#39;t work"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the register link is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Create an account")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/register")

      assert login_html =~ "Create an account"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "You need to reauthenticate"
      refute html =~ "Create an account"
      assert html =~ "Email me a sign-in link"

      assert html =~
               ~s(<input type="email" name="user[email]" id="login_form_magic_email" value="#{user.email}")
    end
  end

  # The LiveView keeps its `Wax.Challenge` in socket state, out of test
  # reach; reconstruct an equivalent one from what it rendered so a
  # hand-crafted assertion (`WebauthnHelper`) verifies against it.
  defp fake_authentication_challenge_from_html(html) do
    %{"challenge" => challenge, "rp_id" => rp_id} =
      Regex.named_captures(
        ~r/id="passkey-login-button"[\s\S]*?data-challenge="(?<challenge>[^"]+)"[\s\S]*?data-rp-id="(?<rp_id>[^"]+)"/,
        html
      )

    Wax.Challenge.new(
      type: :authentication,
      bytes: Base.url_decode64!(challenge, padding: false),
      origin: KammerWeb.Endpoint.url(),
      rp_id: rp_id
    )
  end
end
