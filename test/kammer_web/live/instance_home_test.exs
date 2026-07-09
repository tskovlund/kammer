defmodule KammerWeb.InstanceHomeTest do
  @moduledoc """
  The instance landing page: the admin update notice (SPEC §13) —
  visible to operators only, and only once a check has actually found
  something newer — and the operator's demo-data purge.
  """

  use KammerWeb.ConnCase, async: false

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Communities

  test "an operator sees the notice only once a newer version is recorded", %{conn: conn} do
    operator = instance_operator_fixture()
    conn = log_in_user(conn, operator)

    Communities.get_instance_settings()
    |> Ecto.Changeset.change(latest_known_version: Kammer.version())
    |> Kammer.Repo.update!()

    {:ok, _lv, html} = live(conn, ~p"/")
    refute html =~ "newer version of Kammer"

    Communities.get_instance_settings()
    |> Ecto.Changeset.change(
      latest_known_version: "99.0.0",
      latest_known_release_url: "https://example.com"
    )
    |> Kammer.Repo.update!()

    {:ok, _lv, html} = live(conn, ~p"/")

    assert html =~ "newer version of Kammer"
    assert html =~ "99.0.0"
    assert html =~ "https://example.com"
  end

  test "a plain member never sees the notice, even if one is recorded", %{conn: conn} do
    member = user_fixture()

    Communities.get_instance_settings()
    |> Ecto.Changeset.change(
      latest_known_version: "99.0.0",
      latest_known_release_url: "https://example.com"
    )
    |> Kammer.Repo.update!()

    {:ok, _lv, html} = conn |> log_in_user(member) |> live(~p"/")
    refute html =~ "newer version of Kammer"
  end

  describe "demo purge from the instance home" do
    test "operators can remove the demo community", %{conn: conn} do
      operator = instance_operator_fixture()
      {:ok, demo} = Kammer.Setup.DemoData.create(operator)

      conn = log_in_user(conn, operator)
      {:ok, lv, _html} = live(conn, ~p"/")
      assert has_element?(lv, "#purge-demo-button", "Remove demo")

      render_click(lv, "purge_demo", %{})

      assert Kammer.Repo.get(Kammer.Communities.Community, demo.id) == nil
      refute has_element?(lv, "#purge-demo-button")
    end
  end
end
