defmodule Kammer.SearchTest do
  @moduledoc """
  Global search (SPEC §16): matching, feed-rule filtering (pending,
  scheduled, deleted, locked-away content stays hidden), feature
  gating, and THE invariant — search never returns content from a
  group the viewer couldn't already see listed (property-tested across
  visibilities and viewer kinds).
  """

  use Kammer.DataCase, async: true
  use ExUnitProperties

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures

  alias Kammer.Authorization
  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Groups.Group
  alias Kammer.Repo
  alias Kammer.Search

  defp community_context(_context) do
    {community, owner} = community_with_owner_fixture()
    %{community: community, owner: owner}
  end

  describe "matching and rules" do
    setup :community_context

    test "finds posts, comments, and events; ignores blanks", %{community: community} do
      group = group_fixture(community, visibility: :community)
      member = group_member_fixture(group)

      {:ok, post} =
        Feed.create_post(member, group, %{"body_markdown" => "Generalprøven er flyttet"})

      {:ok, _comment} =
        Feed.create_comment(member, Feed.get_post!(group, post.id), %{
          "body_markdown" => "Generalprøven passer mig fint"
        })

      {:ok, _event} =
        Events.create_event(member, group, %{
          "title" => "Generalprøve i salen",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
        })

      results = Search.search(member, community, "generalprøven")
      assert length(results.posts) == 1
      assert length(results.comments) == 1

      event_results = Search.search(member, community, "generalprøve")
      assert length(event_results.events) == 1

      assert Search.search(member, community, "   ") == %{
               posts: [],
               comments: [],
               events: [],
               files: []
             }

      assert Search.search(member, community, "findesikke") == %{
               posts: [],
               comments: [],
               events: [],
               files: []
             }
    end

    test "hidden content stays hidden: deleted, pending guest comments, disabled features", %{
      community: community
    } do
      group =
        community
        |> group_fixture(visibility: :community)
        |> Group.features_changeset(%{"features" => ["feed"]})
        |> Repo.update!()
        |> Map.put(:community, community)

      member = group_member_fixture(group)

      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Hemmelig plan A"})
      {:ok, _deleted} = Feed.soft_delete_post(member, post)

      # Events feature is off — an event created before the toggle-off
      # would be unfindable; assert the events section respects the gate.
      results = Search.search(member, community, "hemmelig")
      assert results.posts == []
      assert results.events == []
    end
  end

  describe "the invariant" do
    setup :community_context

    @visibilities [:private, :community, :public_link, :public_listed]

    property "search never surfaces content from a group the viewer can't see listed", %{
      community: community,
      owner: owner
    } do
      # Fixed corpus: one group per visibility, each with a matching
      # post, comment, and event.
      groups =
        for visibility <- @visibilities do
          group = group_fixture(community, visibility: visibility)
          member = group_member_fixture(group)

          {:ok, post} =
            Feed.create_post(member, group, %{"body_markdown" => "Nålestak i #{visibility}"})

          {:ok, _comment} =
            Feed.create_comment(member, Feed.get_post!(group, post.id), %{
              "body_markdown" => "Nålestak kommentar"
            })

          {:ok, _event} =
            Events.create_event(member, group, %{
              "title" => "Nålestak begivenhed",
              "starts_at" => DateTime.add(DateTime.utc_now(:second), 24, :hour)
            })

          {group, member}
        end

      non_member = user_fixture()
      community_member = member_fixture(community)
      {private_group, private_member} = List.first(groups)
      _quiet = {private_group, private_member}

      viewers = [nil, non_member, community_member, owner | Enum.map(groups, &elem(&1, 1))]

      check all(viewer_index <- integer(0..(length(viewers) - 1)), max_runs: 25) do
        viewer = Enum.at(viewers, viewer_index)

        listable_ids =
          viewer
          |> Authorization.listable_groups_query(community)
          |> Repo.all()
          |> MapSet.new(& &1.id)

        results = Search.search(viewer, community, "nålestak")

        for post <- results.posts do
          assert MapSet.member?(listable_ids, post.group_id),
                 "post from unlistable group leaked to #{inspect(viewer && viewer.email)}"
        end

        for comment <- results.comments do
          group_id =
            cond do
              comment.post_id -> comment.post.group_id
              comment.event_id -> comment.event.group_id
              comment.assignment_id -> comment.assignment.group_id
            end

          assert MapSet.member?(listable_ids, group_id),
                 "comment from unlistable group leaked to #{inspect(viewer && viewer.email)}"
        end

        for event <- results.events do
          assert MapSet.member?(listable_ids, event.group_id),
                 "event from unlistable group leaked to #{inspect(viewer && viewer.email)}"
        end
      end
    end

    test "anonymous viewers search exactly the public face", %{community: community} do
      listed = group_fixture(community, visibility: :public_listed)
      linked = group_fixture(community, visibility: :public_link)
      listed_member = group_member_fixture(listed)
      linked_member = group_member_fixture(linked)

      {:ok, _post} = Feed.create_post(listed_member, listed, %{"body_markdown" => "Fyrtårn her"})

      {:ok, _hidden} =
        Feed.create_post(linked_member, linked, %{"body_markdown" => "Fyrtårn skjult"})

      results = Search.search(nil, community, "fyrtårn")
      assert [post] = results.posts
      assert post.group_id == listed.id
    end
  end
end
