defmodule Kammer.FilesTest do
  use Kammer.DataCase, async: false

  import Kammer.CommunitiesFixtures

  alias Kammer.Files
  alias Kammer.Storage

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
    %{community: community, group: group, member: member, tmp_dir: tmp_dir}
  end

  defp write_test_image(tmp_dir) do
    # A tiny valid JPEG produced by libvips itself, with EXIF-able room.
    path = Path.join(tmp_dir, "source-image")
    {:ok, image} = Vix.Vips.Operation.black(64, 48)
    :ok = Vix.Vips.Image.write_to_file(image, path <> ".jpg")
    path <> ".jpg"
  end

  describe "image uploads (SPEC §11, §19)" do
    test "re-encodes, sizes, and thumbnails images", %{
      group: group,
      member: member,
      tmp_dir: tmp_dir
    } do
      image_path = write_test_image(tmp_dir)

      assert {:ok, stored_file} =
               Files.create_from_upload(member, group, image_path, %{
                 filename: "band-photo.HEIC.jpg",
                 content_type: "image/jpeg"
               })

      assert stored_file.kind == :image
      assert stored_file.content_type == "image/jpeg"
      assert stored_file.width == 64
      assert stored_file.height == 48
      assert stored_file.thumbnail_key
      assert stored_file.processed_at

      assert {:ok, _display_path} = Storage.path_for(stored_file.storage_key)
      assert {:ok, _thumbnail_path} = Storage.path_for(stored_file.thumbnail_key)
    end
  end

  describe "plain file uploads" do
    test "stores non-images with sanitized names", %{
      group: group,
      member: member,
      tmp_dir: tmp_dir
    } do
      file_path = Path.join(tmp_dir, "notes.txt")
      File.write!(file_path, "setlist")

      assert {:ok, stored_file} =
               Files.create_from_upload(member, group, file_path, %{
                 filename: "../../evil name?.txt",
                 content_type: "text/plain"
               })

      assert stored_file.kind == :file
      refute stored_file.filename =~ "/"
      assert {:ok, path} = Storage.path_for(stored_file.storage_key)
      assert File.read!(path) == "setlist"
    end

    test "neutralizes inline-dangerous content types", %{
      group: group,
      member: member,
      tmp_dir: tmp_dir
    } do
      file_path = Path.join(tmp_dir, "page.html")
      File.write!(file_path, "<script>alert(1)</script>")

      assert {:ok, stored_file} =
               Files.create_from_upload(member, group, file_path, %{
                 filename: "page.html",
                 content_type: "text/html"
               })

      assert stored_file.content_type == "application/octet-stream"
    end
  end

  describe "access control (visibility baseline)" do
    test "group files inherit group visibility", %{
      community: community,
      group: group,
      member: member,
      tmp_dir: tmp_dir
    } do
      file_path = Path.join(tmp_dir, "doc.txt")
      File.write!(file_path, "content")

      {:ok, stored_file} =
        Files.create_from_upload(member, group, file_path, %{
          filename: "doc.txt",
          content_type: "text/plain"
        })

      # Group member: yes. Community member outside the group (community-
      # visible group): yes. Outsider: no.
      assert {:ok, _file} = Files.fetch_accessible_file(member, stored_file.id)

      community_member = member_fixture(community)
      assert {:ok, _file} = Files.fetch_accessible_file(community_member, stored_file.id)

      outsider = Kammer.AccountsFixtures.user_fixture()
      assert {:error, :unauthorized} = Files.fetch_accessible_file(outsider, stored_file.id)
      assert {:error, :unauthorized} = Files.fetch_accessible_file(nil, stored_file.id)
    end

    test "private group files are hidden from plain community members", %{
      community: community,
      tmp_dir: tmp_dir
    } do
      private_group = group_fixture(community, visibility: :private)
      private_member = group_member_fixture(private_group)

      file_path = Path.join(tmp_dir, "secret.txt")
      File.write!(file_path, "secret")

      {:ok, stored_file} =
        Files.create_from_upload(private_member, private_group, file_path, %{
          filename: "secret.txt",
          content_type: "text/plain"
        })

      community_member = member_fixture(community)

      assert {:error, :unauthorized} =
               Files.fetch_accessible_file(community_member, stored_file.id)
    end
  end

  describe "transient expiry (SPEC §5)" do
    test "expired transient files are purged", %{group: group, member: member, tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "temp.txt")
      File.write!(file_path, "temporary")

      {:ok, stored_file} =
        Files.create_from_upload(
          member,
          group,
          file_path,
          %{filename: "temp.txt", content_type: "text/plain"},
          transient: true
        )

      assert stored_file.transient_expires_at

      # Not yet expired: purge does nothing.
      assert Files.purge_expired_transient_files() == 0

      stored_file
      |> Ecto.Changeset.change(
        transient_expires_at: DateTime.add(DateTime.utc_now(:second), -1, :day)
      )
      |> Kammer.Repo.update!()

      assert Files.purge_expired_transient_files() == 1
      assert {:error, :not_found} = Files.fetch_accessible_file(member, stored_file.id)
    end
  end

  describe "upload rate limiting (SPEC §11)" do
    test "create_from_upload is rate limited per uploader", %{
      group: group,
      member: member,
      tmp_dir: tmp_dir
    } do
      for i <- 1..40 do
        file_path = Path.join(tmp_dir, "note-#{i}.txt")
        File.write!(file_path, "note #{i}")

        assert {:ok, _stored_file} =
                 Files.create_from_upload(member, group, file_path, %{
                   filename: "note-#{i}.txt",
                   content_type: "text/plain"
                 })
      end

      file_path = Path.join(tmp_dir, "one-too-many.txt")
      File.write!(file_path, "one too many")

      assert {:error, :rate_limited} =
               Files.create_from_upload(member, group, file_path, %{
                 filename: "one-too-many.txt",
                 content_type: "text/plain"
               })
    end
  end
end
