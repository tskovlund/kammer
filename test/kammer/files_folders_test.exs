defmodule Kammer.FilesFoldersTest do
  use Kammer.DataCase, async: false

  import Kammer.CommunitiesFixtures

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
    group_admin = group_member_fixture(group, :admin)
    member = group_member_fixture(group)

    %{
      community: community,
      community_owner: owner,
      group: group,
      group_admin: group_admin,
      member: member,
      tmp_dir: tmp_dir
    }
  end

  defp write_file(tmp_dir, name, contents \\ "data") do
    path = Path.join(tmp_dir, name)
    File.write!(path, contents)
    path
  end

  describe "folders" do
    test "members create folders; depth is limited", %{group: group, member: member} do
      assert {:ok, folder_one} = Files.create_folder(member, group, nil, "Sheet music")
      assert {:ok, folder_two} = Files.create_folder(member, group, folder_one, "Brass")
      assert {:ok, folder_three} = Files.create_folder(member, group, folder_two, "2026")
      assert {:ok, folder_four} = Files.create_folder(member, group, folder_three, "Spring")
      assert {:error, :too_deep} = Files.create_folder(member, group, folder_four, "Too deep")
    end

    test "admins_only read override hides folder and files from members",
         %{group: group, group_admin: group_admin, member: member, tmp_dir: tmp_dir} do
      {:ok, folder} = Files.create_folder(group_admin, group, nil, "Board only")

      {:ok, folder} =
        Files.update_folder_overrides(group_admin, group, folder, %{read_override: :admins_only})

      # Member: folder invisible in listings; files inside unreadable.
      member_folders = Files.list_folders(member, group)
      refute Enum.any?(member_folders, fn listed -> listed.id == folder.id end)

      admin_folders = Files.list_folders(group_admin, group)
      assert Enum.any?(admin_folders, fn listed -> listed.id == folder.id end)

      upload_path = write_file(tmp_dir, "secret.txt")

      {:ok, _stored_file} =
        Files.upload_to_space(group_admin, group, folder, upload_path, %{
          filename: "secret.txt",
          content_type: "text/plain"
        })

      assert {:error, :unauthorized} = Files.list_files(member, group, folder)
      assert {:ok, [_file]} = Files.list_files(group_admin, group, folder)
    end

    test "write override blocks member uploads but not admins",
         %{group: group, group_admin: group_admin, member: member, tmp_dir: tmp_dir} do
      {:ok, folder} = Files.create_folder(group_admin, group, nil, "Official")

      {:ok, folder} =
        Files.update_folder_overrides(group_admin, group, folder, %{write_override: :admins_only})

      upload_path = write_file(tmp_dir, "doc.txt")

      assert {:error, :unauthorized} =
               Files.upload_to_space(member, group, folder, upload_path, %{
                 filename: "doc.txt",
                 content_type: "text/plain"
               })

      assert {:ok, _stored_file} =
               Files.upload_to_space(group_admin, group, folder, upload_path, %{
                 filename: "doc.txt",
                 content_type: "text/plain"
               })
    end

    test "plain members cannot change overrides or delete folders",
         %{group: group, group_admin: group_admin, member: member} do
      {:ok, folder} = Files.create_folder(member, group, nil, "Shared")

      assert {:error, :unauthorized} =
               Files.update_folder_overrides(member, group, folder, %{read_override: :admins_only})

      assert {:error, :unauthorized} = Files.delete_folder(member, group, folder)
      assert {:ok, _deleted} = Files.delete_folder(group_admin, group, folder)
    end

    test "system folders cannot be deleted", %{group: group, group_admin: group_admin} do
      feed_folder = Files.feed_uploads_folder(group)
      assert {:error, :system_folder} = Files.delete_folder(group_admin, group, feed_folder)
    end

    test "community space is separate from group spaces",
         %{community: community, community_owner: owner, member: member, tmp_dir: tmp_dir} do
      {:ok, _community_folder} = Files.create_folder(owner, community, nil, "Statutes")

      upload_path = write_file(tmp_dir, "statutes.txt")

      {:ok, community_file} =
        Files.upload_to_space(owner, community, nil, upload_path, %{
          filename: "statutes.txt",
          content_type: "text/plain"
        })

      assert community_file.group_id == nil

      # Community members read the community space.
      assert {:ok, files} = Files.list_files(member, community, nil)
      assert Enum.any?(files, fn file -> file.id == community_file.id end)

      # But group listings don't include it.
      member_group = group_fixture(community)
      group_membership_fixture(member_group, member)
      {:ok, group_files} = Files.list_files(member, member_group, nil)
      assert group_files == []
    end
  end

  describe "feed uploads folder" do
    test "feed attachments land in the system folder", %{
      group: group,
      member: member,
      tmp_dir: tmp_dir
    } do
      upload_path = write_file(tmp_dir, "photo.txt")

      {:ok, stored_file} =
        Files.create_from_upload(member, group, upload_path, %{
          filename: "photo.txt",
          content_type: "text/plain"
        })

      feed_folder = Files.feed_uploads_folder(group)
      assert stored_file.folder_id == feed_folder.id

      # Transient files have no file-space home (SPEC §5).
      {:ok, transient_file} =
        Files.create_from_upload(
          member,
          group,
          upload_path,
          %{filename: "temp.txt", content_type: "text/plain"},
          transient: true
        )

      assert transient_file.folder_id == nil
    end
  end

  describe "auto-collections" do
    test "feed collection lists post attachments", %{
      group: group,
      member: member,
      tmp_dir: tmp_dir
    } do
      upload_path = write_file(tmp_dir, "attached.txt")

      {:ok, stored_file} =
        Files.create_from_upload(member, group, upload_path, %{
          filename: "attached.txt",
          content_type: "text/plain"
        })

      {:ok, _post} =
        Kammer.Feed.create_post(member, group, %{
          "body_markdown" => "With file",
          "stored_file_ids" => [stored_file.id]
        })

      collection = Files.list_feed_collection(member, group)
      assert Enum.any?(collection, fn file -> file.id == stored_file.id end)
    end
  end

  describe "storage policy (SPEC §7)" do
    test "quota mode blocks uploads past the cap", %{
      group: group,
      member: member,
      tmp_dir: tmp_dir
    } do
      settings = Kammer.Communities.get_instance_settings()
      settings |> Ecto.Changeset.change(storage_policy: :quota) |> Kammer.Repo.update!()

      group =
        group
        |> Ecto.Changeset.change(storage_quota_bytes: 10)
        |> Kammer.Repo.update!()
        |> Map.put(:community, group.community)

      upload_path = write_file(tmp_dir, "big.txt", String.duplicate("x", 100))

      assert {:error, :quota_exceeded} =
               Files.upload_to_space(member, group, nil, upload_path, %{
                 filename: "big.txt",
                 content_type: "text/plain"
               })

      # Unmetered mode ignores the per-space quota.
      settings = Kammer.Communities.get_instance_settings()
      settings |> Ecto.Changeset.change(storage_policy: :unmetered) |> Kammer.Repo.update!()

      assert {:ok, _stored_file} =
               Files.upload_to_space(member, group, nil, upload_path, %{
                 filename: "big.txt",
                 content_type: "text/plain"
               })
    end

    test "usage and contribution stats", %{group: group, member: member, tmp_dir: tmp_dir} do
      upload_path = write_file(tmp_dir, "counted.txt", "12345")

      {:ok, _stored_file} =
        Files.upload_to_space(member, group, nil, upload_path, %{
          filename: "counted.txt",
          content_type: "text/plain"
        })

      assert Files.space_usage_bytes(group) == 5

      assert [%{user: contributor, bytes: 5}] = Files.contribution_stats(group)
      assert contributor.id == member.id
    end
  end
end
