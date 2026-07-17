defmodule KammerWeb.GroupFeedControllerTest do
  @moduledoc """
  RSS/Atom syndication for public groups (SPEC §8): no secret token,
  gated purely by the same anonymous visibility the group page itself
  uses.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures

  alias Kammer.Feed

  describe "GET /c/:community_slug/g/:group_slug/feed.rss" do
    test "a public_listed group's feed is served to an anonymous visitor", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :public_listed)
      author = group_member_fixture(group)

      {:ok, _post} = Feed.create_post(author, group, %{"body_markdown" => "Hello, world!"})

      conn = get(conn, ~p"/c/#{community.slug}/g/#{group.slug}/feed.rss")

      assert response_content_type(conn, :xml) =~ "application/rss+xml"
      body = response(conn, 200)
      assert body =~ "Hello, world!"
      assert body =~ group.name
    end

    test "a public_link group's feed is also served to an anonymous visitor", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :public_link)

      conn = get(conn, ~p"/c/#{community.slug}/g/#{group.slug}/feed.rss")
      assert response(conn, 200)
    end

    test "an item's <link> is the post's public page, not the group page (issue #341)",
         %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :public_listed)
      author = group_member_fixture(group)
      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Hello, world!"})

      conn = get(conn, ~p"/c/#{community.slug}/g/#{group.slug}/feed.rss")
      body = response(conn, 200)

      group_page = "http://localhost:4000/c/#{community.slug}/g/#{group.slug}"
      assert body =~ "<link>#{group_page}</link>"
      assert body =~ "<link>#{group_page}/p/#{post.id}</link>"

      # The Atom action wires its own post_link_fun on a separate line —
      # pin it too, or a regression there stays invisible to the suite.
      atom_conn = get(conn, ~p"/c/#{community.slug}/g/#{group.slug}/feed.atom")
      atom_body = response(atom_conn, 200)
      assert atom_body =~ ~s(<link href="#{group_page}/p/#{post.id}"/>)
    end

    test "an archived or sealed public group's feed is gone, matching the public API (#345)",
         %{conn: conn} do
      # The feed used to gate on visibility alone, serving a live feed
      # whose every link landed on the SPA error state once the public
      # API (publicly_readable?) refused the group.
      {community, _owner} = community_with_owner_fixture()

      archived =
        community
        |> group_fixture(visibility: :public_listed)
        |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
        |> Kammer.Repo.update!()

      sealed = group_fixture(community, visibility: :public_listed, sealed: true)

      assert conn |> get(~p"/c/#{community.slug}/g/#{archived.slug}/feed.rss") |> response(404)
      assert conn |> get(~p"/c/#{community.slug}/g/#{sealed.slug}/feed.atom") |> response(404)
    end

    test "a community-visibility group 404s for an anonymous visitor", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :community)

      conn = get(conn, ~p"/c/#{community.slug}/g/#{group.slug}/feed.rss")
      assert response(conn, 404)
    end

    test "a private group 404s for an anonymous visitor", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :private)

      conn = get(conn, ~p"/c/#{community.slug}/g/#{group.slug}/feed.rss")
      assert response(conn, 404)
    end

    test "an unknown group 404s", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      conn = get(conn, ~p"/c/#{community.slug}/g/does-not-exist/feed.rss")
      assert response(conn, 404)
    end

    test "an unknown community 404s", %{conn: conn} do
      conn = get(conn, ~p"/c/does-not-exist/g/whatever/feed.rss")
      assert response(conn, 404)
    end

    test "a soft-deleted post is excluded", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :public_listed)
      author = group_member_fixture(group)

      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Ephemeral"})
      {:ok, _deleted} = Feed.soft_delete_post(author, post)

      conn = get(conn, ~p"/c/#{community.slug}/g/#{group.slug}/feed.rss")
      refute response(conn, 200) =~ "Ephemeral"
    end
  end

  describe "GET /c/:community_slug/g/:group_slug/feed.atom" do
    test "a public group's feed is served as Atom", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :public_listed)
      author = group_member_fixture(group)

      {:ok, _post} = Feed.create_post(author, group, %{"body_markdown" => "Atom hello"})

      conn = get(conn, ~p"/c/#{community.slug}/g/#{group.slug}/feed.atom")

      assert response_content_type(conn, :xml) =~ "application/atom+xml"
      assert response(conn, 200) =~ "Atom hello"
    end

    test "a private group 404s", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :private)

      conn = get(conn, ~p"/c/#{community.slug}/g/#{group.slug}/feed.atom")
      assert response(conn, 404)
    end
  end
end
