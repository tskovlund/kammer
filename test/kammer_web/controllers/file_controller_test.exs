defmodule KammerWeb.FileControllerTest do
  @moduledoc """
  The plain-HTTP file download route (SPEC §7): serves stored bytes to
  authorized viewers; anonymous requests for a non-public group's file
  are a 404. This route survives the LiveView removal cut (#187), so it
  lives in a controller test rather than in the file-flow LiveView
  tests.
  """

  use KammerWeb.ConnCase, async: false

  import Kammer.CommunitiesFixtures

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

    %{conn: log_in_user(conn, member), group: group, member: member}
  end

  test "download serves an uploaded file; anonymous access is denied", %{
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
