defmodule KammerWeb.FileFlowsTest do
  @moduledoc """
  LiveView tests for the file-space browser (SPEC §7).
  """

  use KammerWeb.ConnCase, async: false

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Files

  @moduletag :tmp_dir

  setup %{conn: conn, tmp_dir: tmp_dir} do
    previous_uploads_path = Application.get_env(:kammer, :uploads_path)
    Application.put_env(:kammer, :uploads_path, Path.join(tmp_dir, "uploads"))

    on_exit(fn ->
      if previous_uploads_path do
        Application.put_env(:kammer, :uploads_path, previous_uploads_path)
      else
        Application.delete_env(:kammer, :uploads_path)
      end
    end)

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

  test "community file space renders for members", %{conn: conn, community: community} do
    {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}/files")
    assert html =~ community.name
    assert html =~ "Files"
  end

  test "collections switch", %{conn: conn, community: community, group: group} do
    {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}/files")

    html = lv |> element("button", "Images") |> render_click()
    assert html =~ "Nothing here yet"
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

  test "file download route serves an uploaded file", %{
    conn: conn,
    group: group,
    member: member,
    tmp_dir: tmp_dir
  } do
    file_path = Path.join(tmp_dir, "serve-me.txt")
    File.write!(file_path, "hello band")

    {:ok, stored_file} =
      Files.upload_to_space(member, group, nil, file_path, %{
        filename: "serve-me.txt",
        content_type: "text/plain"
      })

    response = get(conn, ~p"/files/#{stored_file.id}/download")
    assert response.status == 200
    assert response.resp_body == "hello band"

    assert Enum.any?(response.resp_headers, fn {name, value} ->
             name == "content-disposition" and value =~ "attachment"
           end)

    # Anonymous access is denied for a community-visibility group's file.
    anonymous_response = build_conn() |> get(~p"/files/#{stored_file.id}/download")
    assert anonymous_response.status == 404
  end
end
