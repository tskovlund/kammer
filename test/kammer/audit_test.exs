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

  describe "list_events/2" do
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

  describe "list_events_page/4" do
    test "paginates newest first with a stable cursor, empty on the last page, admins only" do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)

      for summary <- ["first", "second", "third"] do
        Audit.record(community, owner, "community.settings_updated", summary)
      end

      {first_page, cursor} = Audit.list_events_page(owner, community, nil, 2)
      assert length(first_page) == 2
      assert cursor

      {second_page, nil} = Audit.list_events_page(owner, community, cursor, 2)
      assert length(second_page) == 1

      ids = Enum.map(first_page ++ second_page, & &1.id)
      assert ids == Enum.uniq(ids)

      # The pages cover everything list_events/2 shows, exactly once …
      assert Enum.sort(ids) == Enum.sort(Enum.map(Audit.list_events(owner, community), & &1.id))

      # … strictly descending by the cursor key across the page boundary.
      cursor_keys =
        Enum.map(first_page ++ second_page, fn event ->
          {DateTime.to_iso8601(event.inserted_at), event.id}
        end)

      assert cursor_keys == Enum.sort(cursor_keys, :desc)

      # Same no-oracle gate as list_events/2: a non-admin gets an empty
      # page and no cursor, never an error.
      assert {[], nil} = Audit.list_events_page(member, community, nil, 2)
    end

    test "breaks an inserted_at tie by id, losing nothing at the boundary" do
      # Microsecond timestamps make real ties rare enough that no
      # fixture ever produces one — which left the cursor's ==-and-id
      # arm dead in the suite. Force the tie.
      {community, owner} = community_with_owner_fixture()

      tied =
        for summary <- ["tie-a", "tie-b"] do
          Audit.record(community, owner, "community.settings_updated", summary)
        end

      tied_ids = Enum.map(tied, & &1.id)
      tied_at = DateTime.utc_now()

      Repo.update_all(
        from(event in AuditEvent, where: event.id in ^tied_ids),
        set: [inserted_at: tied_at]
      )

      {[first], cursor} = Audit.list_events_page(owner, community, nil, 1)
      {[second], nil} = Audit.list_events_page(owner, community, cursor, 1)

      # Both tied rows arrive exactly once, descending by id within the
      # tie (uuid string order matches Postgres uuid order).
      assert Enum.sort([first.id, second.id]) == Enum.sort(tied_ids)
      assert first.id > second.id
    end
  end
end
