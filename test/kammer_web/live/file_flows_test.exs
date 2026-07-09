defmodule KammerWeb.FileFlowsTest do
  @moduledoc """
  LiveView tests for the file-space browser (SPEC §7). The plain-HTTP
  download route is covered in `KammerWeb.FileControllerTest` — it
  survives the LiveView removal cut (#187); this file does not.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)

    %{conn: log_in_user(conn, member), community: community, group: group, member: member}
  end

  test "group file space renders with empty state and creates a folder",
       %{conn: conn, community: community, group: group} do
    {:ok, lv, html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}/files")

    assert html =~ "Nothing here yet"

    lv
    |> form(~s(form[phx-submit="create_folder"]))
    |> render_submit(%{"name" => "Sheet music"})

    assert render(lv) =~ "Sheet music"
  end

  test "non-members of a private group cannot open its file space", %{community: community} do
    private_group = group_fixture(community, visibility: :private)
    outsider = member_fixture(community)

    assert {:error, {:live_redirect, %{to: destination}}} =
             build_conn()
             |> log_in_user(outsider)
             |> live(~p"/c/#{community.slug}/g/#{private_group.slug}/files")

    assert destination == "/c/#{community.slug}"
  end
end
