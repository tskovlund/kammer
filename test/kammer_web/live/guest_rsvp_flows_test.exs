defmodule KammerWeb.GuestRsvpFlowsTest do
  @moduledoc """
  The guest RSVP journey end to end (SPEC §6): anonymous visitor on a
  public event → email confirm link → recorded RSVP → management link
  that changes and erases.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Kammer.Events
  alias Kammer.Events.EventRsvp
  alias Kammer.Guests.GuestIdentity
  alias Kammer.Repo

  defp public_event_context(_context) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :public_listed)
    member = group_member_fixture(group)

    {:ok, event} =
      Events.create_event(member, group, %{
        "title" => "Sommerkoncert",
        "starts_at" => DateTime.add(DateTime.utc_now(:second), 96, :hour)
      })

    drain_delivered_emails()
    %{community: community, group: group, member: member, event: event}
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

  describe "anonymous visitors on a public event" do
    setup :public_event_context

    test "see the guest form; members do not", %{
      conn: conn,
      community: community,
      event: event,
      member: member
    } do
      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}/events/#{event.id}")
      assert html =~ "guest-rsvp-form"

      member_conn = log_in_user(build_conn(), member)
      {:ok, _lv, member_html} = live(member_conn, ~p"/c/#{community.slug}/events/#{event.id}")
      refute member_html =~ "guest-rsvp-form"
    end

    test "private-group events stay invisible to anonymous visitors", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :private)
      member = group_member_fixture(group)

      {:ok, event} =
        Events.create_event(member, group, %{
          "title" => "Hemmeligt",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
        })

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/c/#{community.slug}/events/#{event.id}")

      assert to == "/c/#{community.slug}"
    end

    test "the full journey: request, confirm, manage, erase", %{
      conn: conn,
      community: community,
      event: event
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/events/#{event.id}")

      lv
      |> form("#guest-rsvp-form",
        guest: %{display_name: "Gæsten", email: "gaest-rsvp@example.org", status: "yes"}
      )
      |> render_submit()

      assert Repo.aggregate(EventRsvp, :count) == 0
      confirm_token = email_link(~r{/guest/rsvp/confirm/(\S+)})

      confirm_conn = get(build_conn(), ~p"/guest/rsvp/confirm/#{confirm_token}")
      assert redirected_to(confirm_conn) == "/c/#{community.slug}/events/#{event.id}"

      identity = Repo.get_by!(GuestIdentity, email: "gaest-rsvp@example.org")
      assert Repo.get_by!(EventRsvp, event_id: event.id, guest_identity_id: identity.id)

      manage_token = email_link(~r{/guest/manage/([^/\s]+)$}m)
      {:ok, manage_lv, manage_html} = live(build_conn(), ~p"/guest/manage/#{manage_token}")
      assert manage_html =~ "Sommerkoncert"

      manage_lv |> element("button", "Maybe") |> render_click()
      assert Repo.get_by!(EventRsvp, guest_identity_id: identity.id).status == :maybe

      manage_lv |> element("#guest-erase") |> render_click()
      assert Repo.aggregate(GuestIdentity, :count) == 0
      assert Repo.aggregate(EventRsvp, :count) == 0
    end
  end
end
