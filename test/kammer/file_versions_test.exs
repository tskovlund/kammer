defmodule Kammer.FileVersionsTest do
  # async: false — swaps the global :uploads_path like the other
  # storage-touching suites.
  use Kammer.DataCase, async: false

  import Kammer.CommunitiesFixtures

  alias Kammer.Files
  alias Kammer.Files.FileEntry
  alias Kammer.Files.StoredFile
  alias Kammer.Repo

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

  defp upload!(actor, scope, tmp_dir, filename, content \\ "indhold") do
    path = Path.join(tmp_dir, "src-#{System.unique_integer([:positive])}")
    File.write!(path, content)

    {:ok, stored_file} =
      Files.upload_to_space(actor, scope, nil, path, %{
        filename: filename,
        content_type: "application/pdf"
      })

    stored_file
  end

  test "same name = new version; listings show only the current one", %{
    group: group,
    member: member,
    tmp_dir: tmp_dir
  } do
    first = upload!(member, group, tmp_dir, "statutes.pdf", "v1")
    second = upload!(member, group, tmp_dir, "statutes.pdf", "version two")

    assert first.file_entry_id == second.file_entry_id
    entry = Repo.get!(FileEntry, second.file_entry_id)
    assert entry.current_version_id == second.id

    {:ok, listed} = Files.list_files(member, group)
    assert Enum.map(listed, & &1.id) == [second.id]

    {:ok, versions} = Files.list_versions(member, second)
    assert Enum.map(versions, & &1.id) == [second.id, first.id]

    other = upload!(member, group, tmp_dir, "other.pdf")
    refute other.file_entry_id == second.file_entry_id
  end

  test "version deletion: never the last; deleting current repoints", %{
    group: group,
    member: member,
    tmp_dir: tmp_dir
  } do
    only = upload!(member, group, tmp_dir, "solo.pdf")
    assert {:error, :last_version} = Files.delete_version(member, only)

    v1 = upload!(member, group, tmp_dir, "budget.pdf", "one")
    v2 = upload!(member, group, tmp_dir, "budget.pdf", "two")

    outsider = group_member_fixture(group)
    assert {:error, :unauthorized} = Files.delete_version(outsider, v2)

    assert {:ok, _deleted} = Files.delete_version(member, v2)
    entry = Repo.get!(FileEntry, v1.file_entry_id)
    assert entry.current_version_id == v1.id
  end

  test "deleting the file removes the entry and every version", %{
    group: group,
    member: member,
    tmp_dir: tmp_dir
  } do
    _v1 = upload!(member, group, tmp_dir, "setlist.pdf", "one")
    v2 = upload!(member, group, tmp_dir, "setlist.pdf", "two")

    assert {:ok, _} = Files.delete_file(member, v2)
    assert Repo.aggregate(FileEntry, :count) == 0
    refute Repo.get_by(StoredFile, filename: "setlist.pdf")
  end

  test "retention keeps the newest N versions", %{
    community: community,
    tmp_dir: tmp_dir
  } do
    group = group_fixture(community)
    member = group_member_fixture(group)
    Repo.update!(Ecto.Changeset.change(group, version_retention: 2))
    group = Repo.reload!(group)

    for content <- ~w(one two three) do
      upload!(member, group, tmp_dir, "kept.pdf", content)
    end

    [current | _rest] = Repo.all(from(sf in StoredFile, order_by: [desc: sf.inserted_at]))
    {:ok, versions} = Files.list_versions(member, current)
    assert length(versions) == 2
  end

  test "old versions are exactly as accessible as the current one", %{
    community: community,
    group: group,
    member: member,
    tmp_dir: tmp_dir
  } do
    old_version = upload!(member, group, tmp_dir, "parity.pdf", "one")
    current = upload!(member, group, tmp_dir, "parity.pdf", "two")

    non_member = member_fixture(community)

    for viewer <- [member, non_member, nil] do
      current_access = Files.fetch_accessible_file(viewer, current.id)
      old_access = Files.fetch_accessible_file(viewer, old_version.id)

      assert elem(current_access, 0) == elem(old_access, 0),
             "visibility parity broken for #{inspect(viewer && viewer.id)}"
    end
  end

  test "feed attachments stay entry-less and keep listing", %{
    group: group,
    member: member,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "attachment-src")
    File.write!(path, "bilag")

    {:ok, attachment} =
      Files.create_from_upload(member, group, path, %{
        filename: "bilag.pdf",
        content_type: "application/pdf"
      })

    assert attachment.file_entry_id == nil
    folder = Files.feed_uploads_folder(group)
    {:ok, listed} = Files.list_files(member, group, folder)
    assert Enum.map(listed, & &1.id) == [attachment.id]
  end
end
