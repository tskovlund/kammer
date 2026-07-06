defmodule KammerWeb.LegalLiveTest do
  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Legal

  defp operator_fixture do
    user_fixture()
    |> Ecto.Changeset.change(instance_operator: true)
    |> Kammer.Repo.update!()
  end

  describe "public legal pages" do
    test "render the template for visitors", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/legal/imprint")
      assert html =~ "template"

      {:ok, _lv, html} = live(conn, ~p"/legal/privacy")
      assert html =~ "template"
    end

    test "render published text once an operator saves it", %{conn: conn} do
      operator = operator_fixture()

      {:ok, _page} =
        Legal.upsert_page(operator, "imprint", %{
          "content_markdown" => "## Responsible\n\nThe Sample Club."
        })

      {:ok, _lv, html} = live(conn, ~p"/legal/imprint")
      assert html =~ "The Sample Club."
      refute html =~ "This is a template"
    end

    test "an unknown key bounces home", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/legal/terms")
    end
  end

  describe "editing" do
    test "operators can publish from the edit form", %{conn: conn} do
      operator = operator_fixture()
      conn = log_in_user(conn, operator)

      {:ok, lv, html} = live(conn, ~p"/legal/imprint/edit")
      assert html =~ "legal-page-form"

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
      operator = operator_fixture()
      conn = log_in_user(conn, operator)

      {:ok, _lv, html} = live(conn, ~p"/")
      assert html =~ "Edit imprint"

      {:ok, _page} =
        Legal.upsert_page(operator, "imprint", %{"content_markdown" => "Published."})

      {:ok, _lv, html} = live(conn, ~p"/")
      refute html =~ "Edit imprint"
    end

    test "ordinary users never see the nag", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      {:ok, _lv, html} = live(conn, ~p"/")
      refute html =~ "Edit imprint"
    end
  end

  describe "demo purge from the instance home" do
    test "operators can remove the demo community", %{conn: conn} do
      operator = operator_fixture()
      {:ok, demo} = Kammer.Setup.DemoData.create(operator)

      conn = log_in_user(conn, operator)
      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "Remove demo"

      render_click(lv, "purge_demo", %{})

      assert Kammer.Repo.get(Kammer.Communities.Community, demo.id) == nil
      refute render(lv) =~ "Remove demo"
    end
  end
end
