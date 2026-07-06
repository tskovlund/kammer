defmodule Kammer.HomeTest do
  use Kammer.DataCase, async: true

  import Kammer.CommunitiesFixtures

  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Groups
  alias Kammer.Home

  defp future(hours), do: DateTime.add(DateTime.utc_now(:second), hours, :hour)

  test "merges across communities, honors show_in_home, toggles, archiving; sealed included" do
    {community_a, _owner} = community_with_owner_fixture()
    {community_b, _owner} = community_with_owner_fixture()

    group_a = group_fixture(community_a)
    sealed = group_fixture(community_a, sealed: true, visibility: :private)
    group_b = group_fixture(community_b)

    member = group_member_fixture(group_a)
    {:ok, _} = Kammer.Groups.add_member(sealed, member)
    {:ok, _} = Kammer.Groups.add_member(group_b, member)

    {:ok, _post_a} = Feed.create_post(member, group_a, %{"body_markdown" => "A post"})
    {:ok, _sealed_post} = Feed.create_post(member, sealed, %{"body_markdown" => "Board only"})
    {:ok, _post_b} = Feed.create_post(member, group_b, %{"body_markdown" => "B post"})

    {:ok, event_a} =
      Events.create_event(member, group_a, %{"title" => "Koncert", "starts_at" => future(48)})

    {:ok, _event_b} =
      Events.create_event(member, group_b, %{"title" => "Møde", "starts_at" => future(24)})

    # Everything visible by default — sealed included (owner decision).
    posts = Home.recent_activity(member)
    # Same-second inserts: chronological order ties are arbitrary, so
    # assert content, not sequence.
    assert Enum.sort(Enum.map(posts, & &1.body_markdown)) == ["A post", "B post", "Board only"]

    events = Home.upcoming_events(member)
    assert Enum.map(events, & &1.title) == ["Møde", "Koncert"]

    # The member's own switch removes a group from their Home only.
    {:ok, _membership} = Groups.set_show_in_home(member, sealed, false)
    refute "Board only" in Enum.map(Home.recent_activity(member), & &1.body_markdown)

    # Feature toggle: events off removes the group's events from Home.
    admin = group_member_fixture(group_b, :admin)
    {:ok, _group} = Groups.update_group_features(admin, group_b, ["feed", "files"])
    assert Enum.map(Home.upcoming_events(member), & &1.title) == ["Koncert"]
    # ...but its feed posts stay (the feed is not toggleable).
    assert "B post" in Enum.map(Home.recent_activity(member), & &1.body_markdown)

    # Archived groups leave Home entirely.
    group_a_admin = group_member_fixture(group_a, :admin)
    {:ok, _group} = Groups.archive_group(group_a_admin, %{group_a | community: community_a})
    assert Home.upcoming_events(member) == []
    refute "A post" in Enum.map(Home.recent_activity(member), & &1.body_markdown)
    assert event_a.id
  end

  test "non-members see nothing; scheduled posts stay hidden until published" do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)
    outsider = Kammer.AccountsFixtures.user_fixture()

    {:ok, _post} =
      Feed.create_post(member, group, %{
        "body_markdown" => "Later",
        "published_at" => future(24)
      })

    assert Home.recent_activity(outsider) == []
    assert Home.recent_activity(member) == []
  end
end
