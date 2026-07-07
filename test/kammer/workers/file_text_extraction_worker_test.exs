defmodule Kammer.Workers.FileTextExtractionWorkerTest do
  use Kammer.DataCase, async: false
  use Oban.Testing, repo: Kammer.Repo

  import Kammer.CommunitiesFixtures

  alias Kammer.Files
  alias Kammer.Repo
  alias Kammer.Workers.FileTextExtractionWorker

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

  defp upload!(group, member, tmp_dir, name, contents, content_type) do
    path = Path.join(tmp_dir, name)
    File.write!(path, contents)

    {:ok, stored_file} =
      Files.create_from_upload(member, group, path, %{filename: name, content_type: content_type})

    stored_file
  end

  test "enqueued automatically on upload, extracts plaintext", %{
    group: group,
    member: member,
    tmp_dir: tmp_dir
  } do
    stored_file = upload!(group, member, tmp_dir, "notes.txt", "Referat af møde", "text/plain")

    assert_enqueued(worker: FileTextExtractionWorker, args: %{"stored_file_id" => stored_file.id})

    assert :ok =
             perform_job(FileTextExtractionWorker, %{"stored_file_id" => stored_file.id})

    updated = Repo.get!(Kammer.Files.StoredFile, stored_file.id)
    assert updated.extracted_text == "Referat af møde"
    assert updated.text_extracted_at
  end

  test "stamps text_extracted_at without text for a content type with no extractor", %{
    group: group,
    member: member,
    tmp_dir: tmp_dir
  } do
    stored_file =
      upload!(group, member, tmp_dir, "archive.zip", "not really a zip", "application/zip")

    assert :ok = perform_job(FileTextExtractionWorker, %{"stored_file_id" => stored_file.id})

    updated = Repo.get!(Kammer.Files.StoredFile, stored_file.id)
    assert updated.extracted_text == nil
    assert updated.text_extracted_at
  end

  test "tolerates a stored file that no longer exists" do
    assert :ok =
             perform_job(FileTextExtractionWorker, %{"stored_file_id" => Ecto.UUID.generate()})
  end
end
