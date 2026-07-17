defmodule KammerWeb.Api.UploadsTest do
  @moduledoc """
  Feed-attachment uploads and file serving over the API (issue #178):
  multipart upload → `stored_file_ids` on create-post → attachment
  shapes on the post → Bearer-authorized bytes from `/api/v1/files` —
  the whole loop an API client needs, with the same authorization as
  the browser file routes (invisible files answer 404).
  """

  # async: false — swaps the global :uploads_path like the other
  # storage-touching suites.
  use KammerWeb.ConnCase, async: false

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
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

    %{
      community: community,
      group: group,
      member: member,
      base_path: "/api/v1/communities/#{community.slug}/groups/#{group.slug}",
      tmp_dir: tmp_dir
    }
  end

  defp upload_fixture(tmp_dir, contents) do
    path = Path.join(tmp_dir, "setlist-#{System.unique_integer([:positive])}.txt")
    File.write!(path, contents)
    %Plug.Upload{path: path, filename: "setlist.txt", content_type: "text/plain"}
  end

  test "upload, attach to a post, and fetch the bytes back", %{
    member: member,
    base_path: base_path,
    tmp_dir: tmp_dir
  } do
    %{"data" => uploaded} =
      member
      |> api_conn()
      |> post("#{base_path}/uploads", %{"file" => upload_fixture(tmp_dir, "setlist")})
      |> tap(&assert_operation_response(&1, "uploads_create"))
      |> json_response(201)

    assert uploaded["filename"] == "setlist.txt"
    assert uploaded["kind"] == "file"
    assert uploaded["thumbnail_url"] == nil
    assert uploaded["url"] == "/api/v1/files/#{uploaded["id"]}"

    %{"data" => created} =
      member
      |> api_conn()
      |> post("#{base_path}/posts", %{
        "body_markdown" => "Tonight's setlist attached",
        "stored_file_ids" => [uploaded["id"]]
      })
      |> json_response(201)

    assert [attachment] = created["attachments"]
    assert attachment["stored_file_id"] == uploaded["id"]
    assert attachment["position"] == 0
    assert attachment["filename"] == "setlist.txt"

    # The bytes come back over Bearer auth — no browser session needed.
    response = member |> api_conn() |> get(attachment["download_url"])
    assert response.status == 200
    assert response.resp_body == "setlist"
    assert Plug.Conn.get_resp_header(response, "content-disposition") |> hd() =~ "attachment"

    # Group files inherit group visibility: a member of the community
    # can read them (community-visible group); a stranger cannot tell
    # they exist.
    outsider = Kammer.AccountsFixtures.user_fixture()
    assert outsider |> api_conn() |> get(attachment["url"]) |> Map.fetch!(:status) == 404

    # A non-image has no thumbnail.
    assert member
           |> api_conn()
           |> get("/api/v1/files/#{uploaded["id"]}/thumbnail")
           |> Map.fetch!(:status) == 404
  end

  test "uploads are refused for users who cannot post", %{
    community: community,
    base_path: base_path,
    tmp_dir: tmp_dir
  } do
    onlooker = member_fixture(community)

    onlooker
    |> api_conn()
    |> post("#{base_path}/uploads", %{"file" => upload_fixture(tmp_dir, "nope")})
    |> json_response(403)
  end

  test "uploading into a hidden group answers 404, not 403 (no existence oracle, #339)", %{
    community: community,
    tmp_dir: tmp_dir
  } do
    # A private group the caller isn't in: the group itself is invisible,
    # so the upload endpoint answers the same neutral 404 a missing slug
    # would — a 403 here would confirm the private group exists.
    private = group_fixture(community, visibility: :private)
    outsider = member_fixture(community)

    outsider
    |> api_conn()
    |> post("/api/v1/communities/#{community.slug}/groups/#{private.slug}/uploads", %{
      "file" => upload_fixture(tmp_dir, "probe")
    })
    |> json_response(404)
  end

  test "a file over the configured size limit is refused (413)", %{
    member: member,
    base_path: base_path,
    tmp_dir: tmp_dir
  } do
    # Enforced app-side (Files.create_from_upload), so it holds on the
    # API path regardless of the parser's coarser body ceiling (#178
    # review). Drop the per-file limit to make an oversize file cheap.
    Application.put_env(:kammer, :upload_max_megabytes, 1)
    on_exit(fn -> Application.delete_env(:kammer, :upload_max_megabytes) end)

    path = Path.join(tmp_dir, "big.txt")
    File.write!(path, :binary.copy("x", 2 * 1024 * 1024))
    oversize = %Plug.Upload{path: path, filename: "big.txt", content_type: "text/plain"}

    body =
      member
      |> api_conn()
      |> post("#{base_path}/uploads", %{"file" => oversize})
      |> json_response(413)

    assert body["error"]["code"] == "payload_too_large"
  end

  test "a missing file part is a 400", %{member: member, base_path: base_path} do
    member
    |> api_conn()
    |> post("#{base_path}/uploads", %{})
    |> json_response(400)
  end

  test "attaching someone else's upload is refused", %{
    group: group,
    member: member,
    base_path: base_path,
    tmp_dir: tmp_dir
  } do
    other = group_member_fixture(group)

    %{"data" => uploaded} =
      other
      |> api_conn()
      |> post("#{base_path}/uploads", %{"file" => upload_fixture(tmp_dir, "theirs")})
      |> json_response(201)

    body =
      member
      |> api_conn()
      |> post("#{base_path}/posts", %{
        "body_markdown" => "not mine",
        "stored_file_ids" => [uploaded["id"]]
      })
      |> json_response(422)

    assert body["error"]["code"] == "invalid_params"
  end
end
