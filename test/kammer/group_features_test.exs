defmodule Kammer.GroupFeaturesTest do
  use Kammer.DataCase, async: true
  use ExUnitProperties

  import Kammer.CommunitiesFixtures

  alias Kammer.Authorization
  alias Kammer.Events
  alias Kammer.Files
  alias Kammer.Groups
  alias Kammer.Groups.Group

  defp future(hours), do: DateTime.add(DateTime.utc_now(:second), hours, :hour)

  describe "update_group_features/3" do
    test "admins toggle; the feed cannot be turned off; strings are safe" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      admin = group_member_fixture(group, :admin)
      member = group_member_fixture(group)

      assert {:ok, updated} = Groups.update_group_features(admin, group, ["feed", "files"])
      assert updated.features == [:feed, :files]
      refute Group.feature_enabled?(updated, :events)

      # Feed is forced on even when omitted; unknown strings are dropped
      # (never String.to_atom on user input).
      assert {:ok, updated} = Groups.update_group_features(admin, group, ["events", "bogus"])
      assert updated.features == [:feed, :events]

      assert {:error, :unauthorized} = Groups.update_group_features(member, group, ["feed"])
    end
  end

  describe "the gate (ADR 0016): disabled reads as not found" do
    setup do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      admin = group_member_fixture(group, :admin)
      member = group_member_fixture(group)

      {:ok, event} =
        Events.create_event(member, group, %{"title" => "Prøve", "starts_at" => future(48)})

      {:ok, no_events} = Groups.update_group_features(admin, group, ["feed", "files"])
      %{community: community, group: no_events, admin: admin, member: member, event: event}
    end

    test "events: fetch, create, listing, ICS feeds all go dark", %{
      community: community,
      group: group,
      admin: admin,
      member: member,
      event: event
    } do
      assert {:error, :not_found} = Events.fetch_viewable_event(member, community, event.id)

      assert {:error, :not_found} =
               Events.create_event(admin, group, %{"title" => "Nej", "starts_at" => future(24)})

      assert Events.list_upcoming_events(member, community) == []

      token = Events.ensure_group_ics_token(group)
      assert Events.events_for_group_token(token) == nil

      user_token = Events.ensure_user_ics_token(member)
      {_user, events} = Events.events_for_user_token(user_token)
      assert events == []
    end

    test "guests cannot RSVP into a disabled events feature", %{group: group} do
      public = %Group{group | visibility: :public_listed}
      refute Authorization.can_guest_rsvp?(public)
    end

    test "files: group space writes are refused", %{group: group, admin: admin} do
      {:ok, no_files} = Groups.update_group_features(admin, group, ["feed", "events"])

      assert {:error, :not_found} = Files.create_folder(admin, no_files, nil, "Nope")
    end
  end

  property "a disabled feature is exactly as invisible as an unauthorized one" do
    {community, _owner} = community_with_owner_fixture()

    check all(
            visibility <- member_of([:private, :community, :public_link, :public_listed]),
            features <- member_of([[:feed], [:feed, :files], [:feed, :events, :files]]),
            max_runs: 20
          ) do
      group = group_fixture(community, visibility: visibility)
      admin = group_member_fixture(group, :admin)
      member = group_member_fixture(group)

      {:ok, event} =
        Events.create_event(member, group, %{
          "title" => "Prop",
          "starts_at" => future(48)
        })

      {:ok, group} = Groups.update_group_features(admin, group, features)

      case Events.fetch_viewable_event(member, community, event.id) do
        {:ok, _event} -> assert :events in group.features
        {:error, :not_found} -> refute :events in group.features
        {:error, other} -> flunk("unexpected error #{inspect(other)}")
      end
    end
  end
end
