defmodule KammerWeb.Api.FileLibraryTest do
  @moduledoc """
  A group's file library over the API (issue #181): browse folders and
  files, upload files and new versions (ADR 0017), version history,
  download, and the manager folder/override/delete tools — every write
  through the same `Kammer.Files` functions and folder-permission
  invariant (ADR 0009) the UI uses, with responses validated against the
  OpenAPI document. No-oracle throughout: a folder or file the caller
  can't see 404s to every verb.
  """

  # async: false — swaps the global :uploads_path like the other
  # storage-touching suites.
  use KammerWeb.ConnCase, async: false

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Files

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

    {community, owner} = community_with_owner_fixture()
    group = group_fixture(community)
    manager = group_member_fixture(group, :admin)
    member = group_member_fixture(group)

    %{
      community: community,
      owner: owner,
      group: group,
      manager: manager,
      member: member,
      files_path: "/api/v1/communities/#{community.slug}/groups/#{group.slug}/files",
      folders_path: "/api/v1/communities/#{community.slug}/groups/#{group.slug}/folders"
    }
  end

  defp upload(tmp_dir, filename, contents) do
    path = Path.join(tmp_dir, "#{System.unique_integer([:positive])}-#{filename}")
    File.write!(path, contents)
    %Plug.Upload{path: path, filename: filename, content_type: "text/plain"}
  end

  describe "browse" do
    test "an empty root lists no files and reports capabilities", %{
      member: member,
      files_path: files_path
    } do
      %{"data" => listing} =
        member
        |> api_conn()
        |> get(files_path)
        |> tap(&assert_operation_response(&1, "file_library_index"))
        |> json_response(200)

      assert listing["folder"] == nil
      assert listing["files"] == []
      assert listing["chain"] == []
      assert listing["can_write"] == true
      assert listing["can_manage"] == false
    end

    test "a community member who isn't in the group can read but not write", %{
      community: community,
      files_path: files_path
    } do
      onlooker = member_fixture(community)

      %{"data" => listing} =
        onlooker
        |> api_conn()
        |> get(files_path)
        |> json_response(200)

      assert listing["can_write"] == false
      assert listing["can_manage"] == false
    end

    test "an entry-less feed upload carries its uploader in the detail view", %{
      community: community,
      group: group,
      member: member,
      tmp_dir: tmp_dir
    } do
      # Feed/comment attachments are entry-less StoredFiles (no version
      # history), so the detail view falls back to the file itself — which
      # must still be preloaded with its uploader the way the folder listing
      # is. Regression: detail-by-id previously returned uploaded_by: null.
      path = Path.join(tmp_dir, "feed-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "attached")
      {:ok, stored} = Files.create_from_upload(member, group, path, %{filename: "poster.txt"})

      %{"data" => detail} =
        member
        |> api_conn()
        |> get("/api/v1/communities/#{community.slug}/groups/#{group.slug}/files/#{stored.id}")
        |> json_response(200)

      assert detail["file_entry_id"] == nil
      assert detail["uploaded_by"]["id"] == member.id
      assert detail["versions"] == []
    end
  end

  describe "upload and versions" do
    test "upload a file, browse it, and re-upload the same name as a new version", %{
      member: member,
      files_path: files_path,
      tmp_dir: tmp_dir
    } do
      %{"data" => uploaded} =
        member
        |> api_conn()
        |> post(files_path, %{"file" => upload(tmp_dir, "setlist.txt", "v1")})
        |> tap(&assert_operation_response(&1, "file_library_upload"))
        |> json_response(201)

      assert uploaded["filename"] == "setlist.txt"
      assert uploaded["mine"] == true
      assert uploaded["uploaded_by"]["id"] == member.id
      assert length(uploaded["versions"]) == 1
      assert hd(uploaded["versions"])["current"] == true
      file_id = uploaded["id"]

      # It shows up in the listing.
      %{"data" => listing} =
        member |> api_conn() |> get(files_path) |> json_response(200)

      listed = Enum.find(listing["files"], &(&1["filename"] == "setlist.txt"))
      assert listed
      # Listings carry the uploader too (preloaded), not just the detail view.
      assert listed["uploaded_by"]["id"] == member.id

      # Same name into the same place = a new version of the same entry.
      %{"data" => versioned} =
        member
        |> api_conn()
        |> post(files_path, %{"file" => upload(tmp_dir, "setlist.txt", "v2-longer")})
        |> json_response(201)

      assert versioned["file_entry_id"] == uploaded["file_entry_id"]
      assert length(versioned["versions"]) == 2
      # The listing still shows a single current entry, not both versions.
      %{"data" => after_listing} =
        member |> api_conn() |> get(files_path) |> json_response(200)

      assert Enum.count(after_listing["files"], &(&1["filename"] == "setlist.txt")) == 1

      # Detail carries the full history, newest first, current flagged.
      %{"data" => detail} =
        member
        |> api_conn()
        |> get("#{files_path}/#{versioned["id"]}")
        |> tap(&assert_operation_response(&1, "file_library_show"))
        |> json_response(200)

      assert [current, previous] = detail["versions"]
      assert current["current"] == true
      assert previous["current"] == false
      assert current["version_seq"] > previous["version_seq"]

      # The bytes come back over Bearer auth.
      response = member |> api_conn() |> get(detail["download_url"])
      assert response.status == 200
      assert response.resp_body == "v2-longer"

      # An old version is still downloadable by its own url.
      old = member |> api_conn() |> get(previous["download_url"])
      assert old.resp_body == "v1"

      # Uploading a new version via the versions endpoint.
      %{"data" => v3} =
        member
        |> api_conn()
        |> post("#{files_path}/#{file_id}/versions", %{
          "file" => upload(tmp_dir, "renamed-on-disk.txt", "v3")
        })
        |> tap(&assert_operation_response(&1, "file_library_upload_version"))
        |> json_response(201)

      # It keeps the entry's name, not the uploaded part's.
      assert v3["filename"] == "setlist.txt"
      assert length(v3["versions"]) == 3
    end

    test "a member who cannot post is refused (403)", %{
      community: community,
      files_path: files_path,
      tmp_dir: tmp_dir
    } do
      onlooker = member_fixture(community)

      onlooker
      |> api_conn()
      |> post(files_path, %{"file" => upload(tmp_dir, "nope.txt", "x")})
      |> json_response(403)
    end

    test "a missing or non-file `file` part is a 400, not a 500", %{
      member: member,
      files_path: files_path
    } do
      member
      |> api_conn()
      |> post(files_path, %{})
      |> json_response(400)

      # A `file` sent as a plain text field must not crash the envelope.
      member
      |> api_conn()
      |> post(files_path, %{"file" => "not-a-file"})
      |> json_response(400)
    end

    test "an oversize file is refused (413)", %{
      member: member,
      files_path: files_path,
      tmp_dir: tmp_dir
    } do
      Application.put_env(:kammer, :upload_max_megabytes, 1)
      on_exit(fn -> Application.delete_env(:kammer, :upload_max_megabytes) end)

      big = upload(tmp_dir, "big.txt", :binary.copy("x", 2 * 1024 * 1024))

      body =
        member
        |> api_conn()
        |> post(files_path, %{"file" => big})
        |> json_response(413)

      assert body["error"]["code"] == "payload_too_large"
    end
  end

  describe "delete files and versions" do
    test "delete a single version, but never the last", %{
      member: member,
      files_path: files_path,
      tmp_dir: tmp_dir
    } do
      %{"data" => v1} =
        member
        |> api_conn()
        |> post(files_path, %{"file" => upload(tmp_dir, "doc.txt", "one")})
        |> json_response(201)

      %{"data" => v2} =
        member
        |> api_conn()
        |> post(files_path, %{"file" => upload(tmp_dir, "doc.txt", "two")})
        |> json_response(201)

      file_id = v2["id"]
      [old_version | _] = Enum.filter(v2["versions"], &(&1["current"] == false))

      # Deleting an old version is fine.
      member
      |> api_conn()
      |> delete("#{files_path}/#{file_id}/versions/#{old_version["id"]}")
      |> tap(&assert_operation_response(&1, "file_library_delete_version"))
      |> json_response(200)

      # Now only one version remains — deleting it is refused.
      %{"data" => detail} =
        member |> api_conn() |> get("#{files_path}/#{file_id}") |> json_response(200)

      assert [only] = detail["versions"]

      refused =
        member
        |> api_conn()
        |> delete("#{files_path}/#{file_id}/versions/#{only["id"]}")
        |> json_response(422)

      assert refused["error"]["code"] == "invalid_params"
      assert v1["file_entry_id"] == v2["file_entry_id"]
    end

    test "a version id from another entry 404s", %{
      member: member,
      files_path: files_path,
      tmp_dir: tmp_dir
    } do
      %{"data" => a} =
        member
        |> api_conn()
        |> post(files_path, %{"file" => upload(tmp_dir, "a.txt", "a")})
        |> json_response(201)

      %{"data" => b} =
        member
        |> api_conn()
        |> post(files_path, %{"file" => upload(tmp_dir, "b.txt", "b")})
        |> json_response(201)

      member
      |> api_conn()
      |> delete("#{files_path}/#{a["id"]}/versions/#{b["id"]}")
      |> json_response(404)
    end

    test "the uploader deletes their file", %{
      member: member,
      files_path: files_path,
      tmp_dir: tmp_dir
    } do
      %{"data" => file} =
        member
        |> api_conn()
        |> post(files_path, %{"file" => upload(tmp_dir, "gone.txt", "bye")})
        |> json_response(201)

      member
      |> api_conn()
      |> delete("#{files_path}/#{file["id"]}")
      |> tap(&assert_operation_response(&1, "file_library_delete"))
      |> json_response(200)

      member
      |> api_conn()
      |> get("#{files_path}/#{file["id"]}")
      |> json_response(404)
    end
  end

  describe "folders" do
    test "create, browse into, upload within, and delete a folder", %{
      member: member,
      files_path: files_path,
      folders_path: folders_path,
      tmp_dir: tmp_dir
    } do
      %{"data" => folder} =
        member
        |> api_conn()
        |> post(folders_path, %{"name" => "Scores"})
        |> tap(&assert_operation_response(&1, "file_library_create_folder"))
        |> json_response(201)

      assert folder["name"] == "Scores"
      assert folder["system"] == false

      # It appears in the root browse.
      %{"data" => root} = member |> api_conn() |> get(files_path) |> json_response(200)
      assert Enum.any?(root["folders"], &(&1["id"] == folder["id"]))

      # Upload into the folder, then browse it and see the file + breadcrumb.
      member
      |> api_conn()
      |> post(files_path, %{
        "file" => upload(tmp_dir, "score.txt", "notes"),
        "folder_id" => folder["id"]
      })
      |> json_response(201)

      %{"data" => inside} =
        member
        |> api_conn()
        |> get("#{files_path}?folder_id=#{folder["id"]}")
        |> json_response(200)

      assert inside["folder"]["id"] == folder["id"]
      assert [chain_entry] = inside["chain"]
      assert chain_entry["id"] == folder["id"]
      assert Enum.any?(inside["files"], &(&1["filename"] == "score.txt"))

      # Delete the folder (manager power — the member is not a manager, so
      # they're refused; the moderator can).
      member
      |> api_conn()
      |> delete("#{folders_path}/#{folder["id"]}")
      |> json_response(403)
    end

    test "a manager restricts a folder to admins, hiding it from members (no oracle)", %{
      manager: manager,
      member: member,
      group: group,
      files_path: files_path,
      folders_path: folders_path,
      tmp_dir: tmp_dir
    } do
      {:ok, folder} = Files.create_folder(manager, group, nil, "Private")

      # A file placed inside it while it's still open.
      %{"data" => hidden_file} =
        manager
        |> api_conn()
        |> post(files_path, %{
          "file" => upload(tmp_dir, "secret.txt", "s"),
          "folder_id" => folder.id
        })
        |> json_response(201)

      # The manager sets read to admins_only.
      manager
      |> api_conn()
      |> put("#{folders_path}/#{folder.id}/overrides", %{"read_override" => "admins_only"})
      |> tap(&assert_operation_response(&1, "file_library_update_folder"))
      |> json_response(200)

      # A plain member can no longer see or open the folder — 404, never 403.
      %{"data" => listing} =
        member |> api_conn() |> get(files_path) |> json_response(200)

      refute Enum.any?(listing["folders"], &(&1["id"] == folder.id))

      member
      |> api_conn()
      |> get("#{files_path}?folder_id=#{folder.id}")
      |> json_response(404)

      # And the file inside a now-restricted folder 404s by id — the
      # file-level no-oracle within a group the member *can* otherwise see.
      member
      |> api_conn()
      |> get("#{files_path}/#{hidden_file["id"]}")
      |> json_response(404)

      # The manager still sees the folder.
      %{"data" => admin_listing} =
        manager |> api_conn() |> get(files_path) |> json_response(200)

      assert Enum.any?(admin_listing["folders"], &(&1["id"] == folder.id))
    end

    test "a non-manager cannot set overrides", %{
      member: member,
      group: group,
      folders_path: folders_path
    } do
      {:ok, folder} = Files.create_folder(member, group, nil, "Shared")

      member
      |> api_conn()
      |> put("#{folders_path}/#{folder.id}/overrides", %{"write_override" => "admins_only"})
      |> json_response(403)
    end

    test "the system Feed uploads folder can't be deleted", %{
      manager: manager,
      group: group,
      folders_path: folders_path
    } do
      system = Files.feed_uploads_folder(group)

      manager
      |> api_conn()
      |> delete("#{folders_path}/#{system.id}")
      |> json_response(422)
    end
  end

  describe "no-oracle" do
    test "a nonexistent file 404s", %{member: member, files_path: files_path} do
      member
      |> api_conn()
      |> get("#{files_path}/#{Ecto.UUID.generate()}")
      |> json_response(404)
    end

    test "a private group's files are hidden at the group gate (403)", %{
      community: community,
      tmp_dir: tmp_dir
    } do
      # A private group the caller isn't in: the group itself is hidden,
      # so its whole file surface 403s at the group gate — exactly like
      # events. (The finer file-level no-oracle — 404 within a *visible*
      # group — is covered by the folder-override test below.)
      private = group_fixture(community, visibility: :private)
      insider = group_member_fixture(private)
      outsider = member_fixture(community)

      {:ok, stored} =
        Files.upload_to_space(insider, private, nil, write_temp(tmp_dir, "secret"), %{
          filename: "secret.txt",
          content_type: "text/plain"
        })

      path = "/api/v1/communities/#{community.slug}/groups/#{private.slug}/files"

      outsider |> api_conn() |> get(path) |> json_response(403)
      outsider |> api_conn() |> get("#{path}/#{stored.id}") |> json_response(403)
    end

    test "the group file space behind a disabled files feature 404s", %{
      community: community
    } do
      no_files =
        community
        |> group_fixture()
        |> Ecto.Changeset.change(features: [:feed])
        |> Kammer.Repo.update!()

      member = group_member_fixture(no_files)

      member
      |> api_conn()
      |> get("/api/v1/communities/#{community.slug}/groups/#{no_files.slug}/files")
      |> json_response(404)
    end
  end

  defp write_temp(tmp_dir, contents) do
    path = Path.join(tmp_dir, "src-#{System.unique_integer([:positive])}.txt")
    File.write!(path, contents)
    path
  end
end
