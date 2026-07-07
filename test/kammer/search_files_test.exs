defmodule Kammer.SearchFilesTest do
  @moduledoc """
  File search (SPEC §10/§16): filename and extracted-text matching,
  and the folder-permission invariant — a file's search visibility can
  never exceed its folder's (SPEC §7, ADR 0009), riding
  `Authorization.can_read_folder?/4` exactly like `Kammer.Files` does.
  """

  use Kammer.DataCase, async: false

  import Kammer.CommunitiesFixtures

  alias Kammer.Files
  alias Kammer.Search

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
    group = group_fixture(community, visibility: :community)
    group_admin = group_member_fixture(group, :admin)
    member = group_member_fixture(group)

    %{
      community: community,
      owner: owner,
      group: group,
      group_admin: group_admin,
      member: member,
      tmp_dir: tmp_dir
    }
  end

  defp upload!(scope, uploader, folder, tmp_dir, name, contents, content_type \\ "text/plain") do
    path = Path.join(tmp_dir, name)
    File.write!(path, contents)

    {:ok, stored_file} =
      Files.upload_to_space(uploader, scope, folder, path, %{
        filename: name,
        content_type: content_type
      })

    stored_file
  end

  defp with_extracted_text(stored_file, text) do
    stored_file
    |> Ecto.Changeset.change(extracted_text: text, text_extracted_at: DateTime.utc_now(:second))
    |> Kammer.Repo.update!()
  end

  describe "matching" do
    test "matches on filename", %{
      community: community,
      group: group,
      member: member,
      tmp_dir: tmp_dir
    } do
      upload!(group, member, nil, tmp_dir, "Generalprøve-plan.txt", "indhold")

      results = Search.search(member, community, "generalprøve")
      assert [file] = results.files
      assert file.filename == "Generalprøve-plan.txt"
    end

    test "matches on extracted text", %{
      community: community,
      group: group,
      member: member,
      tmp_dir: tmp_dir
    } do
      stored_file = upload!(group, member, nil, tmp_dir, "notes.txt", "uden relevans")
      with_extracted_text(stored_file, "Nålestak i teksten")

      results = Search.search(member, community, "nålestak")
      assert Enum.any?(results.files, &(&1.id == stored_file.id))
    end

    test "old file versions never surface", %{
      community: community,
      group: group,
      member: member,
      tmp_dir: tmp_dir
    } do
      old = upload!(group, member, nil, tmp_dir, "møde-referat.txt", "et")
      new = upload!(group, member, nil, tmp_dir, "møde-referat.txt", "et og to")

      results = Search.search(member, community, "møde")
      ids = Enum.map(results.files, & &1.id)
      assert new.id in ids
      refute old.id in ids
    end
  end

  describe "the folder-permission invariant" do
    test "an admins_only folder hides its files from a plain member but not an admin", %{
      community: community,
      group: group,
      group_admin: group_admin,
      member: member,
      tmp_dir: tmp_dir
    } do
      {:ok, folder} = Files.create_folder(group_admin, group, nil, "Board only")

      {:ok, folder} =
        Files.update_folder_overrides(group_admin, group, folder, %{read_override: :admins_only})

      upload!(group, group_admin, folder, tmp_dir, "hemmelighed.txt", "Bestyrelsens indhold")

      member_results = Search.search(member, community, "hemmelighed")
      assert member_results.files == []

      admin_results = Search.search(group_admin, community, "hemmelighed")
      assert [file] = admin_results.files
      assert file.filename == "hemmelighed.txt"
    end

    test "community-scope files require community membership", %{
      community: community,
      owner: owner,
      tmp_dir: tmp_dir
    } do
      upload!(community, owner, nil, tmp_dir, "vedtægter.txt", "Foreningens grundlag")

      outsider = Kammer.AccountsFixtures.user_fixture()
      assert Search.search(outsider, community, "vedtægter").files == []
      assert Search.search(owner, community, "vedtægter").files != []
    end

    test "a public_link group's files don't surface to non-members (search is surfacing, not link reachability)",
         %{community: community, tmp_dir: tmp_dir} do
      linked_group = group_fixture(community, visibility: :public_link)
      linked_member = group_member_fixture(linked_group)

      upload!(linked_group, linked_member, nil, tmp_dir, "fællessang.txt", "Sangtekster")

      non_member = Kammer.AccountsFixtures.user_fixture()
      assert Search.search(non_member, community, "fællessang").files == []
      assert Search.search(linked_member, community, "fællessang").files != []
    end
  end
end
