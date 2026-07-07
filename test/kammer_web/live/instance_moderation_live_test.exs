defmodule KammerWeb.InstanceModerationLiveTest do
  @moduledoc """
  Operator-only instance-wide ban list (SPEC §11): ban by email, see
  it listed, lift it — through the LiveView, not just the context.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Moderation

  describe "instance moderation" do
    test "operators can ban an email instance-wide and lift it", %{conn: conn} do
      operator = instance_operator_fixture()
      conn = log_in_user(conn, operator)

      {:ok, lv, html} = live(conn, ~p"/instance/moderation")
      assert html =~ "instance-ban-form"

      lv
      |> form("#instance-ban-form",
        instance_ban: %{email: "troublemaker@example.com", reason: "Gentagen chikane"}
      )
      |> render_submit()

      assert Moderation.instance_banned?("troublemaker@example.com")
      html = render(lv)
      assert html =~ "troublemaker@example.com"
      assert html =~ "Gentagen chikane"

      [ban] = Moderation.list_instance_bans(operator)

      lv
      |> element("#unban-instance-#{ban.id}")
      |> render_click()

      refute Moderation.instance_banned?("troublemaker@example.com")
      refute render(lv) =~ "troublemaker@example.com"
    end

    test "an empty email is rejected with a validation error", %{conn: conn} do
      operator = instance_operator_fixture()
      conn = log_in_user(conn, operator)

      {:ok, lv, _html} = live(conn, ~p"/instance/moderation")

      html =
        lv
        |> form("#instance-ban-form", instance_ban: %{email: "", reason: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Moderation.list_instance_bans(operator) == []
    end

    test "non-operators are turned away", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/instance/moderation")
    end

    test "the link is only shown to operators on the instance home", %{conn: conn} do
      operator = instance_operator_fixture()
      conn = log_in_user(conn, operator)
      {:ok, _lv, html} = live(conn, ~p"/")
      assert html =~ "Instance moderation"

      conn = log_in_user(build_conn(), user_fixture())
      {:ok, _lv, html} = live(conn, ~p"/")
      refute html =~ "Instance moderation"
    end
  end
end
