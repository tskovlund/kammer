defmodule Kammer.Workers.PurgeDeletedContentWorkerTest do
  @moduledoc """
  Worker-level coverage for the daily purge tick (SPEC §5): confirms
  `perform/1` actually drives both `Feed.purge_old_deleted_content/0`
  and `Files.purge_expired_transient_files/0`, not just that it
  returns `:ok`. Each purge function's own edge cases are covered in
  depth by `Kammer.FeedTest` and `Kammer.FilesTest`.
  """

  use Kammer.DataCase, async: false
  use Oban.Testing, repo: Kammer.Repo

  import Kammer.CommunitiesFixtures

  alias Kammer.Feed
  alias Kammer.Feed.Post
  alias Kammer.Files
  alias Kammer.Files.StoredFile
  alias Kammer.Repo
  alias Kammer.Workers.PurgeDeletedContentWorker

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
    %{group: group, member: member, tmp_dir: tmp_dir}
  end

  test "purges old soft-deleted posts and expired transient files in one pass", %{
    group: group,
    member: member,
    tmp_dir: tmp_dir
  } do
    {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Gone soon"})
    {:ok, deleted} = Feed.soft_delete_post(member, post)

    deleted
    |> Ecto.Changeset.change(deleted_at: DateTime.add(DateTime.utc_now(:second), -31, :day))
    |> Repo.update!()

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

    stored_file
    |> Ecto.Changeset.change(
      transient_expires_at: DateTime.add(DateTime.utc_now(:second), -1, :day)
    )
    |> Repo.update!()

    assert :ok = perform_job(PurgeDeletedContentWorker, %{})

    assert Repo.get!(Post, post.id).purged_at
    assert Repo.get(StoredFile, stored_file.id) == nil
  end
end
