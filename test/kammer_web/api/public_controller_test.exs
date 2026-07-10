defmodule KammerWeb.Api.PublicControllerTest do
  @moduledoc """
  Tokenless public content reads (issue #185 slice B): a `public_link`
  or `public_listed` group's community/group/feed/post/event are
  readable without a device token, scoped by
  `Kammer.Authorization.publicly_readable?/1` — the same boundary the
  guest RSVP/claim/comment request endpoints already enforce. Anything
  else (`private`, `community`-visibility, sealed, archived, or simply
  nonexistent) answers the identical neutral 404 — no oracle
  (#156/#161), asserted by comparing full response bodies rather than
  just the status code.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures

  import OpenApiSpex.TestAssertions

  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Repo

  setup do
    {community, _owner} = community_with_owner_fixture()
    %{community: community}
  end

  describe "GET /api/v1/public/communities/:community_slug" do
    test "shows the community's public face and only its public_listed groups", %{
      community: community
    } do
      listed = group_fixture(community, visibility: :public_listed, name: "Choir")
      _unlisted_by_link = group_fixture(community, visibility: :public_link, name: "Side room")
      _private = group_fixture(community, visibility: :private, name: "Board")
      _community_only = group_fixture(community, visibility: :community, name: "All members")

      body =
        public_conn()
        |> get(~p"/api/v1/public/communities/#{community.slug}")
        |> tap(&assert_operation_response(&1, "public_community_show"))
        |> json_response(200)

      assert body["data"]["community"]["slug"] == community.slug
      assert [%{"id" => group_id}] = body["data"]["groups"]
      assert group_id == listed.id
    end

    test "an unknown community 404s the same as an unlisted or sealed group's community would" do
      assert public_conn()
             |> get(~p"/api/v1/public/communities/does-not-exist")
             |> json_response(404)
    end
  end

  describe "GET /api/v1/public/communities/:community_slug/groups/:group_slug" do
    test "a public_listed group is readable and matches the Group schema", %{
      community: community
    } do
      group = group_fixture(community, visibility: :public_listed)

      public_conn()
      |> get(~p"/api/v1/public/communities/#{community.slug}/groups/#{group.slug}")
      |> tap(&assert_operation_response(&1, "public_group_show"))
      |> json_response(200)
      |> then(&assert &1["data"]["id"] == group.id)
    end

    test "a public_link group is directly readable by slug, same boundary as its RSS feed", %{
      community: community
    } do
      group = group_fixture(community, visibility: :public_link)

      assert public_conn()
             |> get(~p"/api/v1/public/communities/#{community.slug}/groups/#{group.slug}")
             |> json_response(200)
    end

    test "private, community, sealed, and archived groups 404 identically to a nonexistent one",
         %{
           community: community
         } do
      baseline =
        public_conn()
        |> get(~p"/api/v1/public/communities/#{community.slug}/groups/does-not-exist")
        |> json_response(404)

      unreadable = [
        group_fixture(community, visibility: :private),
        group_fixture(community, visibility: :community),
        group_fixture(community, visibility: :public_listed, sealed: true),
        archive!(group_fixture(community, visibility: :public_listed))
      ]

      for group <- unreadable do
        response =
          public_conn()
          |> get(~p"/api/v1/public/communities/#{community.slug}/groups/#{group.slug}")
          |> json_response(404)

        assert response == baseline
      end
    end
  end

  describe "GET /api/v1/public/communities/:community_slug/groups/:group_slug/posts" do
    setup %{community: community} do
      %{group: group_fixture(community, visibility: :public_listed)}
    end

    test "returns only published, non-deleted posts, cursor-paginated", %{
      community: community,
      group: group
    } do
      author = group_member_fixture(group)
      {:ok, visible} = Feed.create_post(author, group, %{"body_markdown" => "Hello, world"})

      {:ok, to_delete} = Feed.create_post(author, group, %{"body_markdown" => "Oops"})
      {:ok, _deleted} = Feed.soft_delete_post(author, to_delete)

      {:ok, scheduled} =
        Feed.create_post(author, group, %{
          "body_markdown" => "Future",
          "published_at" => DateTime.add(DateTime.utc_now(:second), 3600)
        })

      body =
        public_conn()
        |> get(~p"/api/v1/public/communities/#{community.slug}/groups/#{group.slug}/posts")
        |> tap(&assert_operation_response(&1, "public_group_posts"))
        |> json_response(200)

      ids = Enum.map(body["data"], & &1["id"])
      assert ids == [visible.id]
      refute to_delete.id in ids
      refute scheduled.id in ids
    end

    test "limit clamps the page", %{community: community, group: group} do
      author = group_member_fixture(group)
      for n <- 1..3, do: Feed.create_post(author, group, %{"body_markdown" => "Post #{n}"})

      body =
        public_conn()
        |> get(
          ~p"/api/v1/public/communities/#{community.slug}/groups/#{group.slug}/posts?limit=1"
        )
        |> json_response(200)

      assert length(body["data"]) == 1
      assert body["next_cursor"]
    end

    test "a private group's feed 404s", %{community: community} do
      private_group = group_fixture(community, visibility: :private)

      assert public_conn()
             |> get(
               ~p"/api/v1/public/communities/#{community.slug}/groups/#{private_group.slug}/posts"
             )
             |> json_response(404)
    end
  end

  describe "GET /api/v1/public/communities/:community_slug/groups/:group_slug/posts/:post_id" do
    setup %{community: community} do
      group = group_fixture(community, visibility: :public_listed)
      author = group_member_fixture(group)
      {:ok, post} = Feed.create_post(author, group, %{"body_markdown" => "Guest-commentable"})
      %{group: group, author: author, post: post}
    end

    test "a visible post matches the Post schema", %{
      community: community,
      group: group,
      post: post
    } do
      public_conn()
      |> get(
        ~p"/api/v1/public/communities/#{community.slug}/groups/#{group.slug}/posts/#{post.id}"
      )
      |> tap(&assert_operation_response(&1, "public_post_show"))
      |> json_response(200)
      |> then(&assert &1["data"]["id"] == post.id)
    end

    test "a deleted post 404s the same as a nonexistent one", %{
      community: community,
      group: group,
      author: author,
      post: post
    } do
      {:ok, _deleted} = Feed.soft_delete_post(author, post)

      baseline =
        public_conn()
        |> get(
          ~p"/api/v1/public/communities/#{community.slug}/groups/#{group.slug}/posts/#{Ecto.UUID.generate()}"
        )
        |> json_response(404)

      response =
        public_conn()
        |> get(
          ~p"/api/v1/public/communities/#{community.slug}/groups/#{group.slug}/posts/#{post.id}"
        )
        |> json_response(404)

      assert response == baseline
    end

    test "a post from another group 404s through this group's path (no cross-group IDOR)", %{
      community: community,
      group: group
    } do
      other_group = group_fixture(community, visibility: :public_listed)
      other_author = group_member_fixture(other_group)

      {:ok, other_post} =
        Feed.create_post(other_author, other_group, %{"body_markdown" => "Elsewhere"})

      baseline =
        public_conn()
        |> get(
          ~p"/api/v1/public/communities/#{community.slug}/groups/#{group.slug}/posts/#{Ecto.UUID.generate()}"
        )
        |> json_response(404)

      # `other_post` is real and itself public — but it lives in
      # `other_group`, not `group`. Read through `group`'s path it must
      # be the identical neutral 404 a nonexistent id gets, never
      # reachable by pairing any public group's slug with any post id.
      response =
        public_conn()
        |> get(
          ~p"/api/v1/public/communities/#{community.slug}/groups/#{group.slug}/posts/#{other_post.id}"
        )
        |> json_response(404)

      assert response == baseline
    end
  end

  describe "GET /api/v1/public/communities/:community_slug/events/:event_id" do
    setup %{community: community} do
      %{group: group_fixture(community, visibility: :public_listed)}
    end

    test "shows event details, RSVP counts, and slots — no per-guest RSVP identities", %{
      community: community,
      group: group
    } do
      organizer = group_member_fixture(group)

      {:ok, event} =
        Events.create_event(organizer, group, %{
          "title" => "Open rehearsal",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 3600)
        })

      {:ok, _rsvp} = Events.rsvp(organizer, event, :yes)

      body =
        public_conn()
        |> get(~p"/api/v1/public/communities/#{community.slug}/events/#{event.id}")
        |> tap(&assert_operation_response(&1, "public_event_show"))
        |> json_response(200)

      assert body["data"]["id"] == event.id
      assert body["data"]["rsvp_counts"]["yes"] == 1
      refute Map.has_key?(body["data"], "rsvps")
      assert body["data"]["slots"] == []
    end

    test "a sealed public_listed group's event 404s, matching a nonexistent event", %{
      community: community
    } do
      sealed_group = group_fixture(community, visibility: :public_listed, sealed: true)
      organizer = group_member_fixture(sealed_group)

      {:ok, event} =
        Events.create_event(organizer, sealed_group, %{
          "title" => "Members only, despite the visibility",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 3600)
        })

      baseline =
        public_conn()
        |> get(~p"/api/v1/public/communities/#{community.slug}/events/#{Ecto.UUID.generate()}")
        |> json_response(404)

      response =
        public_conn()
        |> get(~p"/api/v1/public/communities/#{community.slug}/events/#{event.id}")
        |> json_response(404)

      assert response == baseline
    end
  end

  defp public_conn, do: put_req_header(build_conn(), "accept", "application/json")

  defp archive!(group) do
    group
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end
end
