defmodule KammerWeb.Api.ResourcesTest do
  @moduledoc """
  API resources (ADR 0014): reads, writes, cursor pagination — and the
  guarantee that matters most: authorization parity. Whatever a user
  cannot see in the UI, they cannot see through the API, because both
  transports resolve through the same authorization module.
  """

  use KammerWeb.ConnCase, async: true
  use ExUnitProperties

  import Kammer.CommunitiesFixtures

  alias Kammer.Accounts.UserToken
  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Repo

  defp api_conn(user) do
    {token, user_token} = UserToken.build_device_token(user, "test device")
    Repo.insert!(user_token)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

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
    end
  end
end
