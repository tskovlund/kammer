defmodule KammerWeb.LegalLiveTest do
  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Phoenix.LiveViewTest

  import Kammer.CommunitiesFixtures, only: [instance_operator_fixture: 0]

  alias Kammer.Legal

  describe "public legal pages" do
    test "render the template for visitors", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/legal/imprint")
      assert has_element?(lv, "#legal-page-content", "template")

      {:ok, lv, _html} = live(conn, ~p"/legal/privacy")
      assert has_element?(lv, "#legal-page-content", "template")
    end

    test "render published text once an operator saves it", %{conn: conn} do
      operator = instance_operator_fixture()

      {:ok, _page} =
        Legal.upsert_page(operator, "imprint", %{
          "content_markdown" => "## Responsible\n\nThe Sample Club."
        })

      {:ok, lv, _html} = live(conn, ~p"/legal/imprint")
      assert has_element?(lv, "#legal-page-content", "The Sample Club.")
      refute has_element?(lv, "#legal-page-content", "This is a template")
    end

    test "an unknown key bounces home", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/legal/terms")
    end
  end

  describe "editing" do
    test "operators can publish from the edit form", %{conn: conn} do
      operator = instance_operator_fixture()
      conn = log_in_user(conn, operator)

      {:ok, lv, _html} = live(conn, ~p"/legal/imprint/edit")
      assert has_element?(lv, "#legal-page-form")

      lv
      |> form("#legal-page-form", legal_page: %{content_markdown: "## Us\n\nWe run this."})
      |> render_submit()

      assert Legal.published?("imprint")
    end

    test "non-operators are turned away", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      assert {:error, {:live_redirect, %{to: "/legal/imprint"}}} =
               live(conn, ~p"/legal/imprint/edit")
    end
  end

  describe "operator nag" do
    test "the instance home nags operators until the imprint is published", %{conn: conn} do
      operator = instance_operator_fixture()
      conn = log_in_user(conn, operator)

      {:ok, lv, _html} = live(conn, ~p"/")
      assert has_element?(lv, "#edit-imprint-link", "Edit imprint")

      {:ok, _page} =
        Legal.upsert_page(operator, "imprint", %{"content_markdown" => "Published."})

      {:ok, lv, _html} = live(conn, ~p"/")
      refute has_element?(lv, "#edit-imprint-link")
    end
  end
end
