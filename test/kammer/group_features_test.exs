defmodule Kammer.GroupFeaturesTest do
  use Kammer.DataCase, async: true

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

  test "a disabled feature is exactly as invisible as a nonexistent event (ADR 0016)" do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :private)
    admin = group_member_fixture(group, :admin)
    member = group_member_fixture(group)
    onlooker = member_fixture(community)

    {:ok, event} =
      Events.create_event(member, group, %{"title" => "Prop", "starts_at" => future(48)})

    # The unauthorized viewer's refusal at the context level, queried for
    # real: `:unauthorized`, which the API boundary folds into the same
    # 404 as `:not_found` (event_controller's fetch_visible_event; pinned
    # at the transport by EventWritesTest "a hidden event 404s").
    assert {:error, :unauthorized} = Events.fetch_viewable_event(onlooker, community, event.id)

    {:ok, _gated} = Groups.update_group_features(admin, group, ["feed", "files"])

    # For the member of the gated-off group the event now reads exactly
    # like one that never existed — same tuple, nothing to distinguish.
    disabled_result = Events.fetch_viewable_event(member, community, event.id)
    assert disabled_result == {:error, :not_found}

    assert disabled_result ==
             Events.fetch_viewable_event(member, community, Ecto.UUID.generate())
  end
end
