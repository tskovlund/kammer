defmodule KammerWeb.UserAuthTest do
  use KammerWeb.ConnCase, async: true

  alias Kammer.Accounts
  alias KammerWeb.UserAuth

  import Kammer.AccountsFixtures
  import Kammer.ModerationFixtures

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, KammerWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{user: %{user_fixture() | authenticated_at: DateTime.utc_now(:second)}, conn: conn}
  end

  describe "fetch_current_scope_for_user/2" do
    test "assigns the scope from a valid session token", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)

      conn =
        conn |> put_session(:user_token, user_token) |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
      assert conn.assigns.current_scope.user.authenticated_at == user.authenticated_at
    end

    test "assigns the anonymous scope when no session token is present", %{conn: conn} do
      conn = UserAuth.fetch_current_scope_for_user(conn, [])
      refute conn.assigns.current_scope
    end

    test "assigns the anonymous scope for an unknown session token", %{conn: conn, user: user} do
      # A token the store won't recognise: never generated for anyone.
      _ = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> put_session(:user_token, "not-a-real-token")
        |> UserAuth.fetch_current_scope_for_user([])

      refute conn.assigns.current_scope
    end

    test "degrades to the anonymous scope for a banned account (#377)", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      instance_ban_fixture(user.email)

      conn =
        conn |> put_session(:user_token, user_token) |> UserAuth.fetch_current_scope_for_user([])

      # Full lockout (#377): a banned account establishes no scope on any
      # transport — the browser plug refuses a valid session the same way the
      # API plug refuses a valid device token.
      refute conn.assigns.current_scope
    end
  end
end
