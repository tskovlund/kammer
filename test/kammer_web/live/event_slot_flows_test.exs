defmodule KammerWeb.EventSlotFlowsTest do
  @moduledoc """
  Signup slots on the event page (issue #37): managers add slots,
  members claim and release with one tap, anonymous guests get the
  email-confirm form on public events.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Kammer.Events
  alias Kammer.Events.SlotClaim
  alias Kammer.Guests.GuestIdentity
  alias Kammer.Repo

  defp public_event_context(_context) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :public_listed)
    creator = group_member_fixture(group)
    member = group_member_fixture(group)

    {:ok, event} =
      Events.create_event(creator, group, %{
        "title" => "Sommerfest",
        "starts_at" => DateTime.add(DateTime.utc_now(:second), 96, :hour)
      })

    drain_delivered_emails()
    %{community: community, group: group, creator: creator, member: member, event: event}
  end

  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end

  defp email_link(pattern) do
    assert_email_sent(fn email ->
      case Regex.run(pattern, email.text_body, capture: :all_but_first) do
        [token] ->
          send(self(), {:token, token})
          true

        nil ->
          false
      end
    end)

    assert_received {:token, token}
    token
  end

  describe "slots on the event page" do
    setup :public_event_context

    test "manager adds a slot, member claims and releases it", %{
      community: community,
      creator: creator,
      member: member,
      event: event
    } do
      creator_conn = log_in_user(build_conn(), creator)
      {:ok, creator_lv, _html} = live(creator_conn, ~p"/c/#{community.slug}/events/#{event.id}")

      creator_lv
      |> form("#add-slot-form", slot: %{title: "Kage", capacity: "2"})
      |> render_submit()

      [slot] = Repo.all(Kammer.Events.EventSlot)
      assert slot.title == "Kage"

      member_conn = log_in_user(build_conn(), member)

      {:ok, member_lv, member_html} =
        live(member_conn, ~p"/c/#{community.slug}/events/#{event.id}")

      assert member_html =~ "Kage"

      member_lv |> element("#claim-slot-#{slot.id}") |> render_click()
      assert Repo.get_by!(SlotClaim, slot_id: slot.id).user_id == member.id

      member_lv |> element("#unclaim-slot-#{slot.id}") |> render_click()
      assert Repo.aggregate(SlotClaim, :count) == 0
    end

    test "anonymous guest signs up through the email confirm flow", %{
      conn: conn,
      community: community,
      creator: creator,
      event: event
    } do
      {:ok, slot} = Events.create_slot(creator, event, %{"title" => "Kørsel", "capacity" => "4"})

      {:ok, lv, html} = live(conn, ~p"/c/#{community.slug}/events/#{event.id}")
      assert html =~ "guest-claim-form-#{slot.id}"

      lv
      |> form("#guest-claim-form-#{slot.id}",
        guest: %{display_name: "Gæsten", email: "gaest@example.org"}
      )
      |> render_submit()

      assert Repo.aggregate(SlotClaim, :count) == 0

      confirm_token = email_link(~r{/guest/claim/confirm/(\S+)})
      confirm_conn = get(build_conn(), ~p"/guest/claim/confirm/#{confirm_token}")
      assert redirected_to(confirm_conn) == "/c/#{community.slug}/events/#{event.id}"

      identity = Repo.get_by!(GuestIdentity, email: "gaest@example.org")
      assert Repo.get_by!(SlotClaim, guest_identity_id: identity.id).slot_id == slot.id

      # The manage page lists the signup with a release button.
      manage_token = email_link(~r{/guest/manage/([^/\s]+)$}m)
      {:ok, manage_lv, manage_html} = live(build_conn(), ~p"/guest/manage/#{manage_token}")
      assert manage_html =~ "Kørsel"

      claim = Repo.get_by!(SlotClaim, guest_identity_id: identity.id)
      manage_lv |> element("#release-claim-#{claim.id}") |> render_click()
      assert Repo.aggregate(SlotClaim, :count) == 0
    end
  end
end
