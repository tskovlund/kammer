defmodule Kammer.GdprTest do
  @moduledoc """
  Data rights (SPEC §12): the export zip really contains the person's
  data and files, and erasure removes the identity while anonymizing
  authored content to "Deleted user".
  """

  use Kammer.DataCase, async: true

  import Kammer.CommunitiesFixtures

  alias Kammer.Accounts.User
  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Gdpr
  alias Kammer.Repo

  defp member_with_content(_context) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)

    {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Mit livsværk"})

    {:ok, event} =
      Events.create_event(member, group, %{
        "title" => "Min begivenhed",
        "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
      })

    {:ok, _rsvp} = Events.rsvp(member, event, :yes)

    %{community: community, group: group, member: member, post: post, event: event}
  end

  describe "export" do
    setup :member_with_content

    test "the zip holds a data.json with the person's content", %{member: member} do
      assert {:ok, zip_path} = Gdpr.export(member)
      assert File.exists?(zip_path)

      {:ok, entries} = :zip.unzip(String.to_charlist(zip_path), [:memory])
      names = Enum.map(entries, fn {name, _content} -> to_string(name) end)
      assert "data.json" in names

      {_name, json} =
        Enum.find(entries, fn {name, _content} -> to_string(name) == "data.json" end)

      data = Jason.decode!(json)

      assert data["profile"]["email"] == member.email
      assert [%{"body_markdown" => "Mit livsværk"}] = data["posts"]
      assert [%{"event" => "Min begivenhed", "status" => "yes"}] = data["event_rsvps"]

      zip_path |> Path.dirname() |> File.rm_rf!()
    end
  end

  describe "erasure" do
    setup :member_with_content

    test "identity gone, personal rows cascaded, authored content anonymized", %{
      member: member,
      post: post,
      event: event
    } do
      assert :ok = Gdpr.delete_account(member)

      assert Repo.get(User, member.id) == nil

      # Authored content stays, anonymized.
      reloaded_post = Repo.get!(Kammer.Feed.Post, post.id)
      assert reloaded_post.author_user_id == nil

      # Personal rows cascade.
      assert Repo.get_by(Kammer.Events.EventRsvp, event_id: event.id) == nil
      assert Repo.get_by(Kammer.Groups.GroupMembership, user_id: member.id) == nil
    end
  end
end
