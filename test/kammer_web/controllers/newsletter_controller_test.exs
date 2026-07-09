defmodule KammerWeb.NewsletterControllerTest do
  @moduledoc """
  The RFC 8058 one-click unsubscribe endpoint (SPEC §8): email clients
  POST it from the `List-Unsubscribe` header with no session and no
  CSRF token, so it must work bare. This route survives the LiveView
  removal cut (#187), so it lives in a controller test rather than in
  the newsletter-flow LiveView tests.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Swoosh.TestAssertions

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

  test "one-click unsubscribe (RFC 8058): a bare POST with no session or CSRF token still works" do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :public_listed)
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

    assert {:ok, _group, subscription} =
             Newsletters.confirm_subscription(confirm_token, fn manage_token ->
               "http://test/manage/#{manage_token}"
             end)

    manage_token = email_link(~r{http://test/manage/(\S+)})

    conn =
      build_conn()
      |> post(~p"/newsletter/unsubscribe/#{manage_token}/#{subscription.id}")

    assert conn.status == 200
    assert conn.resp_body == "Unsubscribed."
    assert Repo.aggregate(NewsletterSubscription, :count) == 0
  end
end
