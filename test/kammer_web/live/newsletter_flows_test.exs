defmodule KammerWeb.NewsletterFlowsTest do
  @moduledoc """
  The newsletter subscription journey end to end (SPEC §8): anonymous
  visitor on a public group → email confirm link → active subscription
  → management link that changes cadence and unsubscribes. The RFC
  8058 one-click unsubscribe POST is covered in
  `KammerWeb.NewsletterControllerTest` — it survives the LiveView
  removal cut (#187); this file does not.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Kammer.Guests.GuestIdentity
  alias Kammer.Newsletters.NewsletterSubscription
  alias Kammer.Repo

  defp public_group_context(_context) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :public_listed)
    member = group_member_fixture(group)

    drain_delivered_emails()
    %{community: community, group: group, member: member}
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

  describe "anonymous visitors on a public group" do
    setup :public_group_context

    test "see the subscribe form; members do not", %{
      conn: conn,
      community: community,
      group: group,
      member: member
    } do
      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")
      assert html =~ "subscribe-form"

      member_conn = log_in_user(build_conn(), member)
      {:ok, _lv, member_html} = live(member_conn, ~p"/c/#{community.slug}/g/#{group.slug}")
      refute member_html =~ "subscribe-form"
    end

    test "the full journey: request, confirm, manage, unsubscribe", %{
      conn: conn,
      community: community,
      group: group
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      lv
      |> form("#subscribe-form",
        subscribe: %{display_name: "Følger", email: "foelger@example.org", cadence: "per_post"}
      )
      |> render_submit()

      assert Repo.aggregate(NewsletterSubscription, :count) == 0
      confirm_token = email_link(~r{/newsletter/confirm/(\S+)})

      confirm_conn = get(build_conn(), ~p"/newsletter/confirm/#{confirm_token}")
      assert redirected_to(confirm_conn) == "/c/#{community.slug}/g/#{group.slug}"

      identity = Repo.get_by!(GuestIdentity, email: "foelger@example.org")

      subscription =
        Repo.get_by!(NewsletterSubscription, group_id: group.id, guest_identity_id: identity.id)

      assert subscription.cadence == :per_post

      manage_token = email_link(~r{/guest/manage/([^/\s]+)$}m)
      {:ok, manage_lv, manage_html} = live(build_conn(), ~p"/guest/manage/#{manage_token}")
      assert manage_html =~ group.name

      manage_lv
      |> form("#cadence-#{subscription.id}", %{cadence: "weekly"})
      |> render_change()

      assert Repo.reload!(subscription).cadence == :weekly

      manage_lv |> element("#unsubscribe-#{subscription.id}") |> render_click()
      assert Repo.aggregate(NewsletterSubscription, :count) == 0
    end
  end
end
