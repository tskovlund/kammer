defmodule KammerWeb.Api.EventWritesTest do
  @moduledoc """
  Events write parity over the API (issue #180): create/edit/delete
  (single and recurring, ADR 0019), per-occurrence cancel/reinstate,
  signup-slot claim/unclaim and management, and the shared comment
  engine — every write through the same context functions the UI uses,
  with responses validated against the OpenAPI document.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Events

  defp context(_tags) do
    {community, owner} = community_with_owner_fixture()
    group = group_fixture(community)
    creator = group_member_fixture(group)
    member = group_member_fixture(group)

    %{
      community: community,
      owner: owner,
      group: group,
      creator: creator,
      member: member,
      create_path: ~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/events"
    }
  end

  setup :context

  defp starts_at(hours \\ 48), do: DateTime.add(DateTime.utc_now(:second), hours, :hour)

  defp create_event(user, community, group, attrs \\ %{}) do
    {:ok, event} =
      Events.create_event(
        user,
        group,
        Map.merge(%{"title" => "Fest", "starts_at" => starts_at()}, attrs)
      )

    %{event: event, community: community}
  end

  describe "create" do
    test "a member creates a single event", %{
      community: community,
      creator: creator,
      create_path: path
    } do
      body =
        creator
        |> api_conn()
        |> post(path, %{"title" => "Sommerfest", "starts_at" => DateTime.to_iso8601(starts_at())})
        |> tap(&assert_operation_response(&1, "events_create"))
        |> json_response(201)

      assert body["data"]["title"] == "Sommerfest"
      assert body["data"]["series_id"] == nil
      assert body["data"]["cancelled"] == false

      # It appears in the community's upcoming list.
      %{"data" => events} =
        creator
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/events")
        |> json_response(200)

      assert Enum.any?(events, &(&1["title"] == "Sommerfest"))
    end

    test "a stored non-http location_url is never emitted over the API (issue #247)", %{
      community: community,
      creator: creator,
      group: group
    } do
      # Simulates a row written before the changeset validation existed;
      # the serializer is the choke point every client (PWA, future
      # native apps) reads through, so it must not emit the raw value.
      %{event: event} = create_event(creator, community, group)

      event
      |> Ecto.Changeset.change(location_url: "javascript:alert(1)")
      |> Kammer.Repo.update!()

      %{"data" => events} =
        creator
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/events")
        |> json_response(200)

      assert %{"location_url" => nil} = Enum.find(events, &(&1["id"] == event.id))
    end

    test "a recurring series returns the first occurrence with a series_id", %{
      community: community,
      creator: creator,
      create_path: path
    } do
      body =
        creator
        |> api_conn()
        |> post(path, %{
          "title" => "Ugentlig øvning",
          "starts_at" => DateTime.to_iso8601(starts_at()),
          "recurrence" => %{
            "frequency" => "weekly",
            "until" => Date.to_iso8601(Date.add(Date.utc_today(), 21))
          }
        })
        |> tap(&assert_operation_response(&1, "events_create"))
        |> json_response(201)

      assert body["data"]["series_id"]

      # All materialized occurrences show up in the list.
      %{"data" => events} =
        creator
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/events")
        |> json_response(200)

      assert Enum.count(events, &(&1["title"] == "Ugentlig øvning")) >= 3
    end

    test "someone who cannot see the group cannot create in it", %{community: community} do
      # A community member who isn't in a private group can't view it, so
      # the create is refused the same way viewing it would be.
      private = group_fixture(community, visibility: :private)
      outsider = member_fixture(community)

      outsider
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/groups/#{private.slug}/events", %{
        "title" => "Nope",
        "starts_at" => DateTime.to_iso8601(starts_at())
      })
      |> json_response(403)
    end
  end

  describe "edit and delete" do
    test "the creator edits; another member may not", %{
      community: community,
      group: group,
      creator: creator,
      member: member
    } do
      %{event: event} = create_event(creator, community, group)
      path = ~p"/api/v1/communities/#{community.slug}/events/#{event.id}"

      body =
        creator
        |> api_conn()
        |> put(path, %{"title" => "Ændret titel"})
        |> tap(&assert_operation_response(&1, "events_update"))
        |> json_response(200)

      assert body["data"]["title"] == "Ændret titel"

      member
      |> api_conn()
      |> put(path, %{"title" => "Kapret"})
      |> json_response(403)
    end

    test "the creator deletes", %{community: community, group: group, creator: creator} do
      %{event: event} = create_event(creator, community, group)

      creator
      |> api_conn()
      |> delete(~p"/api/v1/communities/#{community.slug}/events/#{event.id}")
      |> tap(&assert_operation_response(&1, "events_delete"))
      |> json_response(200)

      creator
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/events/#{event.id}")
      |> json_response(404)
    end
  end

  describe "cancel and reinstate an occurrence" do
    test "cancel then reinstate", %{community: community, group: group, creator: creator} do
      %{event: event} = create_event(creator, community, group)
      base = ~p"/api/v1/communities/#{community.slug}/events/#{event.id}/cancellation"

      cancelled =
        creator
        |> api_conn()
        |> put(base)
        |> tap(&assert_operation_response(&1, "events_cancel"))
        |> json_response(200)

      assert cancelled["data"]["cancelled"] == true

      reinstated =
        creator
        |> api_conn()
        |> delete(base)
        |> tap(&assert_operation_response(&1, "events_uncancel"))
        |> json_response(200)

      assert reinstated["data"]["cancelled"] == false
    end
  end

  describe "signup slots" do
    test "manager adds a slot; a member claims and unclaims it", %{
      community: community,
      group: group,
      creator: creator,
      member: member
    } do
      %{event: event} = create_event(creator, community, group)
      event_path = ~p"/api/v1/communities/#{community.slug}/events/#{event.id}"

      created =
        creator
        |> api_conn()
        |> post("#{event_path}/slots", %{"title" => "Kage", "capacity" => 1})
        |> tap(&assert_operation_response(&1, "events_create_slot"))
        |> json_response(200)

      [slot] = created["data"]["slots"]
      assert slot["title"] == "Kage"
      assert slot["capacity"] == 1
      assert slot["taken"] == 0

      claimed =
        member
        |> api_conn()
        |> put("#{event_path}/slots/#{slot["id"]}/claim")
        |> tap(&assert_operation_response(&1, "events_claim_slot"))
        |> json_response(200)

      [claimed_slot] = claimed["data"]["slots"]
      assert claimed_slot["taken"] == 1
      assert Enum.any?(claimed_slot["claimants"], &(&1["id"] == member.id))

      released =
        member
        |> api_conn()
        |> delete("#{event_path}/slots/#{slot["id"]}/claim")
        |> tap(&assert_operation_response(&1, "events_unclaim_slot"))
        |> json_response(200)

      assert hd(released["data"]["slots"])["taken"] == 0
    end

    test "a full slot refuses a second claim with 422 slot_full", %{
      community: community,
      group: group,
      creator: creator,
      member: member
    } do
      %{event: event} = create_event(creator, community, group)
      event_path = ~p"/api/v1/communities/#{community.slug}/events/#{event.id}"

      {:ok, slot} = Events.create_slot(creator, event, %{"title" => "Kør", "capacity" => 1})

      creator
      |> api_conn()
      |> put("#{event_path}/slots/#{slot.id}/claim")
      |> json_response(200)

      body =
        member
        |> api_conn()
        |> put("#{event_path}/slots/#{slot.id}/claim")
        |> json_response(422)

      assert body["error"]["code"] == "slot_full"
    end

    test "the event manager deletes a slot; a plain member may not", %{
      community: community,
      group: group,
      creator: creator,
      member: member
    } do
      %{event: event} = create_event(creator, community, group)
      event_path = ~p"/api/v1/communities/#{community.slug}/events/#{event.id}"

      {:ok, slot} = Events.create_slot(creator, event, %{"title" => "Kage", "capacity" => 2})

      # The event is visible to the member, so the refusal is an honest
      # 403 — no-oracle 404s are for events the caller can't see at all.
      member
      |> api_conn()
      |> delete("#{event_path}/slots/#{slot.id}")
      |> json_response(403)

      %{"data" => after_delete} =
        creator
        |> api_conn()
        |> delete("#{event_path}/slots/#{slot.id}")
        |> tap(&assert_operation_response(&1, "events_delete_slot"))
        |> json_response(200)

      assert after_delete["slots"] == []
    end

    test "a plain member cannot add a slot", %{
      community: community,
      group: group,
      creator: creator,
      member: member
    } do
      %{event: event} = create_event(creator, community, group)

      member
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/events/#{event.id}/slots", %{
        "title" => "Nej",
        "capacity" => 2
      })
      |> json_response(403)
    end
  end

  describe "comments" do
    test "a member comments, edits, reacts, and deletes their own", %{
      community: community,
      group: group,
      creator: creator,
      member: member
    } do
      %{event: event} = create_event(creator, community, group)
      base = ~p"/api/v1/communities/#{community.slug}/events/#{event.id}/comments"

      created =
        member
        |> api_conn()
        |> post(base, %{"body_markdown" => "Jeg kommer!"})
        |> tap(&assert_operation_response(&1, "events_create_comment"))
        |> json_response(201)

      comment_id = created["data"]["id"]
      assert created["data"]["body_markdown"] == "Jeg kommer!"

      edited =
        member
        |> api_conn()
        |> put("#{base}/#{comment_id}", %{"body_markdown" => "Jeg kommer måske"})
        |> tap(&assert_operation_response(&1, "events_update_comment"))
        |> json_response(200)

      assert edited["data"]["body_markdown"] == "Jeg kommer måske"
      assert edited["data"]["edited_at"]

      reacted =
        member
        |> api_conn()
        |> post("#{base}/#{comment_id}/reactions", %{"emoji" => "🎉"})
        |> tap(&assert_operation_response(&1, "events_react_comment"))
        |> json_response(200)

      assert reacted["data"]["reactions"]["🎉"] == 1
      assert "🎉" in reacted["data"]["my_reactions"]

      deleted =
        member
        |> api_conn()
        |> delete("#{base}/#{comment_id}")
        |> tap(&assert_operation_response(&1, "events_delete_comment"))
        |> json_response(200)

      assert deleted["data"]["deleted"] == true

      # The event detail carries its comments, tombstone included.
      %{"data" => shown} =
        member
        |> api_conn()
        |> get(~p"/api/v1/communities/#{community.slug}/events/#{event.id}")
        |> json_response(200)

      assert Enum.any?(shown["comments"], &(&1["id"] == comment_id))
    end
  end

  describe "no-oracle on writes" do
    test "a nonexistent event 404s to every verb", %{community: community, member: member} do
      id = Ecto.UUID.generate()

      member
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/events/#{id}", %{"title" => "x"})
      |> json_response(404)

      member
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/events/#{id}/comments", %{
        "body_markdown" => "x"
      })
      |> json_response(404)
    end

    test "a hidden event 404s to a write, not 403 (no existence oracle)", %{
      community: community,
      member: member
    } do
      # An event in a private group the caller isn't in: `member` can't see
      # it, so a write must read as 404 — indistinguishable from a
      # nonexistent event — never 403, which would confirm it exists.
      private = group_fixture(community, visibility: :private)
      insider = group_member_fixture(private)
      %{event: event} = create_event(insider, community, private)
      {:ok, comment} = Events.create_comment(insider, event, %{"body_markdown" => "Hemmelig"})

      member
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/events/#{event.id}", %{"title" => "x"})
      |> json_response(404)

      member
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/events/#{event.id}/comments", %{
        "body_markdown" => "x"
      })
      |> json_response(404)

      member
      |> api_conn()
      |> post(
        ~p"/api/v1/communities/#{community.slug}/events/#{event.id}/comments/#{comment.id}/report",
        %{"reason" => "x"}
      )
      |> json_response(404)
    end
  end
end
