defmodule Kammer.AuditTest do
  @moduledoc """
  The append-only audit log (SPEC §11): entries record with a
  precomputed summary, and only community admins may read them back.
  """

  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures

  alias Kammer.Audit
  alias Kammer.Audit.AuditEvent

  describe "record/5" do
    test "accepts a community struct or a bare id, with or without an actor" do
      {community, owner} = community_with_owner_fixture()

      event = Audit.record(community, owner, "community.settings_updated", "did a thing")
      assert %AuditEvent{} = event
      assert event.community_id == community.id
      assert event.actor_user_id == owner.id
      assert event.metadata == %{}

      system_event =
        Audit.record(community.id, nil, "member.banned", "system did a thing", %{"k" => "v"})

      assert system_event.actor_user_id == nil
      assert system_event.metadata == %{"k" => "v"}
    end
  end

  describe "list_events/3" do
    test "community admins see entries, newest first; everyone else sees nothing" do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)
      outsider = user_fixture()

      Audit.record(community, owner, "community.settings_updated", "first")
      Audit.record(community, owner, "community.settings_updated", "second")

      assert [%{summary: "second"}, %{summary: "first"}] = Audit.list_events(owner, community)
      assert Audit.list_events(member, community) == []
      assert Audit.list_events(outsider, community) == []
      assert Audit.list_events(nil, community) == []
    end

    test "is scoped to the community" do
      {community_a, owner_a} = community_with_owner_fixture()
      {community_b, _owner_b} = community_with_owner_fixture()

      Audit.record(community_a, owner_a, "community.settings_updated", "in A")
      Audit.record(community_b, owner_a, "community.settings_updated", "in B")

      assert [%{summary: "in A"}] = Audit.list_events(owner_a, community_a)
    end
  end
end
