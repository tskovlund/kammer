defmodule KammerWeb.InstanceHomeTest do
  @moduledoc """
  The instance landing page: the admin update notice (SPEC §13) —
  visible to operators only, and only once a check has actually found
  something newer — and the merged Home lens (ADR 0015).
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

  test "recent activity shows the group as author for group-authored posts (#167)", %{
    conn: conn
  } do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    group_owner = group_member_fixture(group, :owner)
    member = group_member_fixture(group)

    {:ok, _post} =
      Kammer.Feed.create_post(group_owner, group, %{
        "body_markdown" => "Announcement from the board",
        "author_type" => "group"
      })

    {:ok, lv, _html} = conn |> log_in_user(member) |> live(~p"/")

    assert has_element?(lv, "#home-activity", "Announcement from the board")
    assert has_element?(lv, "#home-activity", group.name)
    refute has_element?(lv, "#home-activity", group_owner.display_name)
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
