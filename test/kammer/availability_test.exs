defmodule Kammer.AvailabilityTest do
  @moduledoc """
  Date-finding polls (issue #39): the feature gate (OFF by default),
  the permission matrix, answer upserts, and close/convert semantics —
  converting creates exactly one event and closes the poll.
  """

  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures

  alias Kammer.Availability
  alias Kammer.Availability.AvailabilityPoll
  alias Kammer.Events.Event
  alias Kammer.Groups.Group
  alias Kammer.Repo

  defp availability_group_context(extra_attrs \\ []) do
    {community, _owner} = community_with_owner_fixture()

    # Features aren't castable at creation (ADR 0016): enable the atom
    # the way the settings page does.
    group =
      community
      |> group_fixture(extra_attrs)
      |> Group.features_changeset(%{"features" => ["feed", "events", "availability"]})
      |> Repo.update!()
      |> Map.put(:community, community)

    creator = group_member_fixture(group)
    member = group_member_fixture(group)

    %{community: community, group: group, creator: creator, member: member}
  end

  defp dates(count) do
    for offset_days <- 1..count do
      DateTime.add(DateTime.utc_now(:second), offset_days * 24, :hour)
    end
  end

  describe "the feature gate" do
    test "availability ships OFF by default — new groups don't have it" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)

      refute Group.feature_enabled?(group, :availability)
      member = group_member_fixture(group)

      assert {:error, :not_found} =
               Availability.create_poll(member, group, %{"title" => "Møde"}, dates(2))

      assert Availability.list_open_polls(member, community) == []
    end

    test "polls of gated-off groups disappear from view" do
      %{community: community, group: group, creator: creator} = availability_group_context()
      {:ok, poll} = Availability.create_poll(creator, group, %{"title" => "Møde"}, dates(2))

      {:ok, _group} =
        group
        |> Group.features_changeset(%{"features" => ["feed", "events"]})
        |> Repo.update()

      assert Availability.list_open_polls(creator, community) == []
      assert {:error, :not_found} = Availability.fetch_viewable_poll(creator, poll.id)
    end
  end

  describe "creating" do
    test "creates a poll with sorted, positioned options" do
      %{group: group, creator: creator} = availability_group_context()
      [first, second, third] = dates(3)

      {:ok, poll} =
        Availability.create_poll(creator, group, %{"title" => "Møde"}, [third, first, second])

      assert [option_one, option_two, option_three] = poll.options
      assert option_one.starts_at == first
      assert option_two.starts_at == second
      assert option_three.starts_at == third
      assert Enum.map(poll.options, & &1.position) == [0, 1, 2]
    end

    test "requires a title and at least one date; non-members refused" do
      %{group: group, creator: creator} = availability_group_context()

      assert {:error, :no_options} =
               Availability.create_poll(creator, group, %{"title" => "Møde"}, [])

      assert {:error, %Ecto.Changeset{}} =
               Availability.create_poll(creator, group, %{"title" => ""}, dates(1))

      outsider = user_fixture()

      assert {:error, :unauthorized} =
               Availability.create_poll(outsider, group, %{"title" => "Møde"}, dates(1))
    end
  end

  describe "responding" do
    test "answers upsert per person per date; outsiders and closed polls refuse" do
      %{group: group, creator: creator, member: member} = availability_group_context()
      {:ok, poll} = Availability.create_poll(creator, group, %{"title" => "Møde"}, dates(2))
      [option, _other] = poll.options

      assert {:ok, response} = Availability.respond(member, option, :yes)
      assert response.answer == :yes

      assert {:ok, changed} = Availability.respond(member, option, :if_needed)
      assert changed.answer == :if_needed
      assert changed.id == response.id

      outsider = user_fixture()
      assert {:error, :unauthorized} = Availability.respond(outsider, option, :yes)

      {:ok, _closed} = Availability.close_poll(creator, poll)
      assert {:error, :closed} = Availability.respond(member, option, :no)
    end
  end

  describe "closing and converting" do
    test "converting creates exactly one event and closes the poll" do
      %{community: community, group: group, creator: creator, member: member} =
        availability_group_context()

      {:ok, poll} = Availability.create_poll(creator, group, %{"title" => "Møde"}, dates(2))
      [winner, _loser] = poll.options

      assert {:error, :unauthorized} = Availability.convert_to_event(member, poll, winner)

      assert {:ok, closed_poll, event} = Availability.convert_to_event(creator, poll, winner)
      assert AvailabilityPoll.closed?(closed_poll)
      assert closed_poll.converted_event_id == event.id
      assert event.title == "Møde"
      assert event.starts_at == winner.starts_at
      assert Repo.aggregate(Event, :count) == 1

      # Closed means closed: no re-convert, gone from the open list.
      assert {:error, :closed} = Availability.convert_to_event(creator, closed_poll, winner)
      assert Availability.list_open_polls(creator, community) == []
    end

    test "closing without converting; moderators may manage others' polls" do
      %{group: group, creator: creator, member: member} = availability_group_context()
      moderator = group_member_fixture(group, :admin)

      {:ok, poll} = Availability.create_poll(creator, group, %{"title" => "Møde"}, dates(1))

      assert {:error, :unauthorized} = Availability.close_poll(member, poll)
      assert {:ok, closed} = Availability.close_poll(moderator, poll)
      assert AvailabilityPoll.closed?(closed)
      assert closed.converted_event_id == nil
      assert Repo.aggregate(Event, :count) == 0
    end
  end

  describe "visibility" do
    test "polls are visible exactly where the group is" do
      %{group: group, creator: creator} =
        availability_group_context(visibility: :private)

      {:ok, poll} = Availability.create_poll(creator, group, %{"title" => "Møde"}, dates(1))

      outsider = user_fixture()
      assert {:error, _reason} = Availability.fetch_viewable_poll(outsider, poll.id)
      assert {:error, _reason} = Availability.fetch_viewable_poll(nil, poll.id)
      assert {:ok, _poll, _group} = Availability.fetch_viewable_poll(creator, poll.id)
    end
  end
end
