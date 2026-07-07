defmodule KammerWeb.InstanceHomeTest do
  @moduledoc """
  The admin update notice on the instance landing page (SPEC §13):
  visible to operators only, and only once a check has actually found
  something newer.
  """

  use KammerWeb.ConnCase, async: false

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Communities
  alias Kammer.UpdateCheck

  test "an operator sees the notice once a newer version is recorded", %{conn: conn} do
    operator = instance_operator_fixture()

    Communities.get_instance_settings()
    |> Ecto.Changeset.change(
      latest_known_version: "99.0.0",
      latest_known_release_url: "https://example.com"
    )
    |> Kammer.Repo.update!()

    {:ok, _lv, html} = conn |> log_in_user(operator) |> live(~p"/")

    assert html =~ "newer version of Kammer"
    assert html =~ "99.0.0"
    assert html =~ "https://example.com"
  end

  test "an operator sees nothing when already up to date", %{conn: conn} do
    operator = instance_operator_fixture()

    Communities.get_instance_settings()
    |> Ecto.Changeset.change(latest_known_version: UpdateCheck.current_version())
    |> Kammer.Repo.update!()

    {:ok, _lv, html} = conn |> log_in_user(operator) |> live(~p"/")
    refute html =~ "newer version of Kammer"
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
end
