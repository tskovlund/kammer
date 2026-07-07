defmodule KammerWeb.InstanceSettingsLiveTest do
  @moduledoc """
  Operator-only content-minimized email toggle (SPEC §9 / ADR 0011).
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Communities

  defp operator_fixture do
    user_fixture()
    |> Ecto.Changeset.change(instance_operator: true)
    |> Kammer.Repo.update!()
  end

  describe "instance settings" do
    test "operators can toggle content-minimized email mode", %{conn: conn} do
      operator = operator_fixture()
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

    test "the link is only shown to operators on the instance home", %{conn: conn} do
      operator = operator_fixture()
      conn = log_in_user(conn, operator)
      {:ok, _lv, html} = live(conn, ~p"/")
      assert html =~ "Instance settings"

      conn = log_in_user(build_conn(), user_fixture())
      {:ok, _lv, html} = live(conn, ~p"/")
      refute html =~ "Instance settings"
    end
  end
end
