defmodule KammerWeb.NewsletterControllerTest do
  @moduledoc """
  The newsletter unsubscribe endpoints (SPEC §8, issues #233 and #239):
  the RFC 8058 one-click POST email clients fire from the
  `List-Unsubscribe` header (no session, no CSRF token, so it must work
  bare), and the GET confirm page a human lands on from the same URL.
  Both take a scoped, single-purpose token — never the guest's
  full-power management token, since mail gateways auto-fetch the
  header with no human in the loop — and both answer a neutral 200
  regardless of validity. Only the POST deletes: GET is a safe method,
  and link-prefetching mail scanners GET every URL in an email. These
  routes are the only newsletter surface that stayed server-rendered
  through the LiveView removal cut (#187); confirming a subscription
  moved to the JSON API (`test/kammer_web/api/newsletter_test.exs`).
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

  # A live subscription plus the unsubscribe URL its delivery email's
  # header carried — the exact URL both endpoints serve.
  defp subscribed_header_url! do
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

    unsubscribe_header_url()
  end

  test "one-click unsubscribe (RFC 8058): a bare POST with no session or CSRF token still works" do
    url = subscribed_header_url!()

    conn = build_conn() |> post(url)

    assert conn.status == 200
    assert conn.resp_body =~ "You&#39;re unsubscribed."
    assert Repo.aggregate(NewsletterSubscription, :count) == 0
  end

  test "the GET renders a confirm page and deletes nothing; the POST its form fires deletes" do
    # The regression #239 fixed: the GET used to delete inline, so a
    # link-prefetching mail scanner silently unsubscribed the guest.
    url = subscribed_header_url!()

    conn = build_conn() |> get(url)

    assert conn.status == 200
    assert response_content_type(conn, :html)
    assert conn.resp_body =~ "Confirm unsubscribe"
    # The page sets its own strict CSP (see .sobelow-conf's Config.CSP
    # note — Sobelow can't see controller-set headers) and, as a
    # token-bearing URL, must never be stored by a shared cache.
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "form-action 'self'"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert Repo.aggregate(NewsletterSubscription, :count) == 1

    # Follow the form exactly as a browser would — its action must be
    # the route that deletes, or the page is a dead end.
    assert [action] =
             Regex.run(~r{<form method="post" action="([^"]+)"}, conn.resp_body,
               capture: :all_but_first
             )

    confirmed = build_conn() |> post(action)
    assert confirmed.status == 200
    assert Repo.aggregate(NewsletterSubscription, :count) == 0
  end

  test "both endpoints answer an invalid token with the same page as a valid one — no oracle" do
    url = subscribed_header_url!()
    valid_get = build_conn() |> get(url) |> Map.fetch!(:resp_body)

    garbage_get =
      build_conn() |> get(~p"/newsletter/unsubscribe/garbage") |> Map.fetch!(:resp_body)

    replace_token = &String.replace(&1, ~r{unsubscribe/[^"]+}, "unsubscribe/TOKEN")
    assert replace_token.(valid_get) == replace_token.(garbage_get)

    garbage_post = build_conn() |> post(~p"/newsletter/unsubscribe/garbage")
    assert garbage_post.status == 200
    assert garbage_post.resp_body =~ "You&#39;re unsubscribed."
  end
end
