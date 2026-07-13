defmodule KammerWeb.NewsletterControllerTest do
  @moduledoc """
  The newsletter unsubscribe endpoints (SPEC §8, issue #233): the RFC
  8058 one-click POST email clients fire from the `List-Unsubscribe`
  header (no session, no CSRF token, so it must work bare), and the
  plain GET twin a human might follow. Both take a scoped,
  single-purpose token — never the guest's full-power management token,
  since mail gateways auto-fetch the header with no human in the loop —
  and both answer a neutral 200 regardless of validity. These routes are
  the only newsletter surface that stayed server-rendered through the
  LiveView removal cut (#187); confirming a subscription moved to the
  JSON API (`test/kammer_web/api/newsletter_test.exs`).
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Swoosh.TestAssertions

  alias Kammer.Feed
  alias Kammer.Newsletters
  alias Kammer.Newsletters.NewsletterSubscription
  alias Kammer.Repo

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

  # Pulls the URL out of the (auto-fetched, never-clicked)
  # `List-Unsubscribe` header itself, rather than assuming its shape —
  # the point of this suite is to prove what that header actually
  # carries.
  defp unsubscribe_header_url do
    assert_email_sent(fn email ->
      send(self(), {:header, email.headers["List-Unsubscribe"]})
      true
    end)

    assert_received {:header, "<" <> rest}
    String.trim_trailing(rest, ">")
  end

  test "one-click unsubscribe (RFC 8058): a bare POST with no session or CSRF token still works" do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :public_listed)
    member = group_member_fixture(group)
    drain_delivered_emails()

    assert :ok =
             Newsletters.request_subscription(
               group,
               %{
                 "email" => "engangsklik@example.org",
                 "display_name" => "Klikker",
                 "cadence" => "per_post"
               },
               client_ip: nil,
               confirm_url_fun: fn token -> "http://test/confirm/#{token}" end
             )

    confirm_token = email_link(~r{http://test/confirm/(\S+)})

    assert {:ok, _group, _subscription} =
             Newsletters.confirm_subscription(confirm_token, fn manage_token ->
               "http://test/manage/#{manage_token}"
             end)

    drain_delivered_emails()

    {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Nyt indlæg!"})
    assert :ok = Newsletters.notify_subscribers(post)

    conn = build_conn() |> post(unsubscribe_header_url())

    assert conn.status == 200
    assert conn.resp_body == "Unsubscribed."
    assert Repo.aggregate(NewsletterSubscription, :count) == 0
  end

  test "an invalid or garbage scoped token still gets the same neutral 200" do
    conn = build_conn() |> post(~p"/newsletter/unsubscribe/garbage")

    assert conn.status == 200
    assert conn.resp_body == "Unsubscribed."
  end

  test "the human-facing GET unsubscribe answers 200 in plain text, neutral on a bad token" do
    conn = build_conn() |> get(~p"/newsletter/unsubscribe/garbage")

    assert conn.status == 200
    assert conn.resp_body == "You're unsubscribed."
  end
end
