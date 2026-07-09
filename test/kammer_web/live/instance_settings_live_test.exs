defmodule KammerWeb.InstanceSettingsLiveTest do
  @moduledoc """
  Operator-only content-minimized email toggle (SPEC §9 / ADR 0011).
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Communities

  describe "instance settings" do
    test "operators can toggle content-minimized email mode", %{conn: conn} do
      operator = instance_operator_fixture()
      conn = log_in_user(conn, operator)

      {:ok, lv, html} = live(conn, ~p"/instance/settings")
      assert html =~ "instance-settings-form"
      refute Communities.get_instance_settings().content_minimized_emails

      lv
      |> form("#instance-settings-form", instance_settings: %{content_minimized_emails: "true"})
      |> render_submit()

      assert Communities.get_instance_settings().content_minimized_emails
    end

    test "non-operators are turned away", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/instance/settings")
    end
  end
end
