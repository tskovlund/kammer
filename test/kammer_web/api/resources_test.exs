defmodule KammerWeb.Api.ResourcesTest do
  @moduledoc """
  API resources (ADR 0014): reads, writes, cursor pagination — and the
  guarantee that matters most: authorization parity. Whatever a user
  cannot see in the UI, they cannot see through the API, because both
  transports resolve through the same authorization module.

  The parity property below sweeps reads (posts index) and writes
  (event creation) over the visibility × sealed × viewer space. Every
  other API controller funnels through the same single gate
  (`Groups.fetch_viewable_group`), verified per controller by the
  deterministic gate tests in FeedWritesTest, EventWritesTest, and
  FileLibraryTest — file uploads are multipart and stay deterministic
  there rather than joining this property.
  """

  use KammerWeb.ConnCase, async: true
  use ExUnitProperties

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers

  alias Kammer.Events
  alias Kammer.Feed

  defp context(_tags) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)
    %{community: community, group: group, member: member}
  end

  describe "communities and groups" do
    setup :context

    test "a member lists their communities and visible groups", %{
      community: community,
      group: group,
      member: member
    } do
      sealed = group_fixture(community, sealed: true, visibility: :private)

      body =
        member |> api_conn() |> get(~p"/api/v1/communities") |> json_response(200)

      assert [%{"slug" => slug}] = body["data"]
      assert slug == community.slug

      body =
        member
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/groups")
        |> json_response(200)

      slugs = Enum.map(body["data"], & &1["slug"])
      assert group.slug in slugs
      refute sealed.slug in slugs
    end
  end

  describe "posts" do
    setup :context

    test "create, list with cursor pagination, comment", %{
      community: community,
      group: group,
      member: member
    } do
      for index <- 1..3 do
        {:ok, _post} = Feed.create_post(member, group, %{"body_markdown" => "Post #{index}"})
      end

      path = ~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/posts"

      %{"data" => [first, second], "next_cursor" => cursor} =
        member |> api_conn() |> get(path <> "?limit=2") |> json_response(200)

      assert cursor
      assert first["author"]["type"] == "user"

      %{"data" => [third], "next_cursor" => nil} =
        member |> api_conn() |> get(path <> "?limit=2&after=#{cursor}") |> json_response(200)

      bodies = Enum.map([first, second, third], & &1["body_markdown"])
      assert Enum.sort(bodies) == ["Post 1", "Post 2", "Post 3"]

      # Pagination's documented defensive contract: a garbage cursor
      # reads as no cursor (the first page again, never a 500)...
      %{"data" => [garbage_first, _second]} =
        member
        |> api_conn()
        |> get(path <> "?limit=2&after=garbage")
        |> json_response(200)

      assert garbage_first["id"] == first["id"]

      # ...and an absurd limit clamps into [1, 100] instead of erroring.
      %{"data" => clamped} =
        member |> api_conn() |> get(path <> "?limit=999999") |> json_response(200)

      assert length(clamped) == 3

      %{"data" => created} =
        member
        |> api_conn()
        |> post(path, %{"body_markdown" => "Via API"})
        |> json_response(201)

      assert created["body_markdown"] == "Via API"

      %{"data" => comment} =
        member
        |> api_conn()
        |> post(path <> "/#{created["id"]}/comments", %{"body_markdown" => "First!"})
        |> json_response(201)

      assert comment["body_markdown"] == "First!"
      assert comment["author"]["type"] == "user"
      assert comment["author"]["display_name"]
    end

    test "a group-authored post serializes the group as author, not the human", %{
      community: community,
      group: group,
      member: member
    } do
      admin = group_member_fixture(group, :admin)

      {:ok, _post} =
        Feed.create_post(admin, group, %{
          "body_markdown" => "Fra bestyrelsen",
          "author_type" => "group"
        })

      %{"data" => [post]} =
        member
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/posts")
        |> json_response(200)

      assert post["author"] == %{
               "type" => "group",
               "id" => group.id,
               "display_name" => group.name
             }
    end

    test "a malformed post id in comment creation is a 404, not a 500", %{
      community: community,
      group: group,
      member: member
    } do
      body =
        member
        |> api_conn()
        |> post(
          ~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/posts/not-a-uuid/comments",
          %{"body_markdown" => "x"}
        )
        |> json_response(404)

      assert body["error"]["code"]
    end

    test "a moderation-queued post is marked pending and rejects others' comments", %{
      community: community,
      member: member
    } do
      approval_group = group_fixture(community, approval_queue: true)
      poster = group_member_fixture(approval_group)
      group_membership_fixture(approval_group, member)

      {:ok, pending} = Feed.create_post(poster, approval_group, %{"body_markdown" => "Venter"})
      assert pending.pending_approval

      path = ~p"/api/v1/communities/#{community.slug}/groups/#{approval_group.slug}/posts"

      # The author sees their own queued post, explicitly marked.
      %{"data" => [post]} = poster |> api_conn() |> get(path) |> json_response(200)
      assert post["pending_approval"] == true

      # Another member can't see it — and commenting on it answers 404,
      # exactly like a post that doesn't exist, even knowing the id.
      member
      |> api_conn()
      |> post(path <> "/#{pending.id}/comments", %{"body_markdown" => "sneaky"})
      |> json_response(404)

      # The author can comment on their own queued post.
      poster
      |> api_conn()
      |> post(path <> "/#{pending.id}/comments", %{"body_markdown" => "note"})
      |> json_response(201)
    end
  end

  describe "events" do
    setup :context

    test "list, show with my_rsvp, RSVP round-trip", %{
      community: community,
      group: group,
      member: member
    } do
      {:ok, event} =
        Events.create_event(member, group, %{
          "title" => "API-koncert",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
        })

      %{"data" => [listed]} =
        member
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/events")
        |> json_response(200)

      assert listed["title"] == "API-koncert"

      %{"data" => %{"status" => "yes"}} =
        member
        |> api_conn()
        |> put(~p"/api/v1/communities/#{community.slug}/events/#{event.id}/rsvp", %{
          "status" => "yes"
        })
        |> json_response(200)

      %{"data" => shown} =
        member
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/events/#{event.id}")
        |> json_response(200)

      assert shown["my_rsvp"] == "yes"
      assert shown["rsvp_counts"]["yes"] == 1
    end
  end

  describe "home" do
    setup :context

    test "mirrors the merged lens", %{group: group, member: member} do
      {:ok, _post} = Feed.create_post(member, group, %{"body_markdown" => "Hjemme"})

      body = member |> api_conn() |> get(~p"/api/v1/home") |> json_response(200)

      assert [%{"body_markdown" => "Hjemme", "community" => %{}, "group" => %{}}] =
               body["recent_activity"]
    end
  end

  property "authorization parity: what the UI hides, the API hides" do
    {community, _owner} = community_with_owner_fixture()

    check all(
            visibility <- member_of([:private, :community, :public_link, :public_listed]),
            sealed <- boolean(),
            viewer_kind <- member_of([:group_member, :community_member, :outsider]),
            max_runs: 25
          ) do
      group = group_fixture(community, visibility: visibility, sealed: sealed)
      author = group_member_fixture(group)
      {:ok, _post} = Feed.create_post(author, group, %{"body_markdown" => "Parity"})

      viewer =
        case viewer_kind do
          :group_member -> author
          :community_member -> member_fixture(community)
          :outsider -> Kammer.AccountsFixtures.user_fixture()
        end

      ui_visible? =
        match?({:ok, _group}, Kammer.Groups.fetch_viewable_group(viewer, community, group.slug))

      response =
        viewer
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/posts")

      case {ui_visible?, response.status} do
        {true, 200} -> :ok
        {false, status} when status in [403, 404] -> :ok
        mismatch -> flunk("UI/API visibility mismatch: #{inspect(mismatch)}")
      end

      # Write parity over the same configuration: a hidden group refuses
      # writes without confirming existence; a visible one answers on the
      # merits (created, or an honest 403 for a viewer without rights).
      write_response =
        viewer
        |> api_conn()
        |> post(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/events", %{
          "title" => "Parity write",
          "starts_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(:second), 48, :hour))
        })

      case {ui_visible?, write_response.status} do
        {true, status} when status in [201, 403] -> :ok
        {false, status} when status in [403, 404] -> :ok
        mismatch -> flunk("UI/API write-parity mismatch: #{inspect(mismatch)}")
      end
    end
  end
end
