defmodule KammerWeb.SearchFlowsTest do
  @moduledoc """
  The search page end to end (SPEC §16): members find their content,
  anonymous visitors search only the public face.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Feed
  alias Kammer.Files.StoredFile
  alias Kammer.Repo

  defp search_context(_context) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :community)
    member = group_member_fixture(group)

    {:ok, post} =
      Feed.create_post(member, group, %{"body_markdown" => "Sommerkoncerten er bekræftet"})

    %{community: community, group: group, member: member, post: post}
  end

  # No real bytes needed to render a search result — only a DB row that
  # matches the same shape `Kammer.Files` produces.
  defp stored_file_fixture(group, filename) do
    %StoredFile{}
    |> StoredFile.create_changeset(%{
      "filename" => filename,
      "content_type" => "text/plain",
      "byte_size" => 42,
      "storage_key" => "test/#{Ecto.UUID.generate()}.txt",
      "community_id" => group.community_id,
      "group_id" => group.id
    })
    |> Repo.insert!()
  end

  describe "searching" do
    setup :search_context

    test "a member finds a post and lands on it", %{
      community: community,
      group: group,
      member: member,
      post: post
    } do
      conn = log_in_user(build_conn(), member)
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/search")

      lv |> form("#search-form", %{q: "sommerkoncerten"}) |> render_change()

      assert has_element?(
               lv,
               "#search-result-post-#{post.id}",
               "Sommerkoncerten er bekræftet"
             )

      assert has_element?(lv, "#search-result-post-#{post.id}", group.name)
    end

    test "anonymous visitors don't see community-only content", %{
      conn: conn,
      community: community,
      post: post
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/search")

      lv |> form("#search-form", %{q: "sommerkoncerten"}) |> render_change()

      refute has_element?(lv, "#search-result-post-#{post.id}")
      assert has_element?(lv, "p", "Nothing found")
    end

    test "a member finds a file by name", %{community: community, group: group, member: member} do
      stored_file = stored_file_fixture(group, "koncertplakat.pdf")

      conn = log_in_user(build_conn(), member)
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/search")

      lv |> form("#search-form", %{q: "koncertplakat"}) |> render_change()

      assert has_element?(
               lv,
               "#search-result-file-#{stored_file.id}",
               "koncertplakat.pdf"
             )

      assert has_element?(lv, "#search-result-file-#{stored_file.id}[href*='/download']")
    end
  end
end
