defmodule KammerWeb.UserLive.DevicesTest do
  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
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
end
