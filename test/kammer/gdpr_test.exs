defmodule Kammer.GdprTest do
  @moduledoc """
  Data rights (SPEC §12): the export zip really contains the person's
  data and files, and erasure removes the identity while anonymizing
  authored content to "Deleted user".
  """

  # async: false — swaps the global :uploads_path like the other
  # storage-touching suites.
  use Kammer.DataCase, async: false

  import Kammer.CommunitiesFixtures

  alias Kammer.Accounts.User
  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Files
  alias Kammer.Gdpr
  alias Kammer.Repo

  @moduletag :tmp_dir

  defp member_with_content(%{tmp_dir: tmp_dir}) do
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

    {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Mit livsværk"})
    {:ok, comment} = Feed.create_comment(member, post, %{"body_markdown" => "Min kommentar"})

    {:ok, event} =
      Events.create_event(member, group, %{
        "title" => "Min begivenhed",
        "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
      })

    {:ok, _rsvp} = Events.rsvp(member, event, :yes)

    upload_path = Path.join(tmp_dir, "setliste.txt")
    File.write!(upload_path, "mine sange")

    {:ok, stored_file} =
      Files.upload_to_space(member, group, nil, upload_path, %{
        filename: "setliste.txt",
        content_type: "text/plain"
      })

    %{
      community: community,
      group: group,
      member: member,
      post: post,
      comment: comment,
      event: event,
      stored_file: stored_file
    }
  end

  describe "export" do
    setup :member_with_content

    test "the zip holds a data.json with the person's content and their uploaded files", %{
      member: member,
      stored_file: stored_file
    } do
      assert {:ok, zip_path} = Gdpr.export(member)
      assert File.exists?(zip_path)

      {:ok, entries} = :zip.unzip(String.to_charlist(zip_path), [:memory])
      names = Enum.map(entries, fn {name, _content} -> to_string(name) end)
      assert "data.json" in names

      # Every file the person uploaded rides along under files/.
      assert "files/#{stored_file.id}-setliste.txt" in names

      {_name, json} =
        Enum.find(entries, fn {name, _content} -> to_string(name) == "data.json" end)

      data = Jason.decode!(json)

      assert data["profile"]["email"] == member.email
      assert [%{"body_markdown" => "Mit livsværk"}] = data["posts"]
      assert [%{"body_markdown" => "Min kommentar"}] = data["comments"]
      assert [%{"event" => "Min begivenhed", "status" => "yes"}] = data["event_rsvps"]

      zip_path |> Path.dirname() |> File.rm_rf!()
    end
  end

  describe "erasure" do
    setup :member_with_content

    test "identity gone, personal rows cascaded, authored content anonymized", %{
      member: member,
      post: post,
      comment: comment,
      event: event,
      stored_file: stored_file
    } do
      assert :ok = Gdpr.delete_account(member)

      assert Repo.get(User, member.id) == nil

      # Authored content stays, anonymized — posts and comments alike.
      reloaded_post = Repo.get!(Kammer.Feed.Post, post.id)
      assert reloaded_post.author_user_id == nil

      reloaded_comment = Repo.get!(Kammer.Feed.Comment, comment.id)
      assert reloaded_comment.author_user_id == nil

      # Uploaded files remain the group's shared memory, uploader anonymized.
      reloaded_file = Repo.get!(Kammer.Files.StoredFile, stored_file.id)
      assert reloaded_file.uploader_user_id == nil

      # Personal rows cascade.
      assert Repo.get_by(Kammer.Events.EventRsvp, event_id: event.id) == nil
      assert Repo.get_by(Kammer.Groups.GroupMembership, user_id: member.id) == nil
    end
  end
end
