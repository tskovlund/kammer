defmodule Kammer.Workers.NewsletterDigestWorkerTest do
  @moduledoc """
  Worker-level coverage for the newsletter digest tick (SPEC §8) — that
  `perform/1` actually drives `Newsletters.due_subscriptions/1` and
  `Newsletters.deliver_digest/2` end to end via `perform_job/2`.
  Cadence math and email content are covered in depth by
  `Kammer.NewslettersTest`.
  """

  use Kammer.DataCase, async: true
  use Oban.Testing, repo: Kammer.Repo

  import Kammer.CommunitiesFixtures
  import Swoosh.TestAssertions

  alias Kammer.Feed
  alias Kammer.Newsletters
  alias Kammer.Repo
  alias Kammer.Workers.NewsletterDigestWorker

  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end

  defp confirmed_subscription!(group, cadence) do
    attrs = %{
      "email" => "folger#{System.unique_integer([:positive])}@example.org",
      "display_name" => "Følger",
      "cadence" => cadence
    }

    assert :ok =
             Newsletters.request_subscription(group, attrs,
               client_ip: nil,
               confirm_url_fun: fn token -> "http://test/confirm/#{token}" end
             )

    assert_email_sent(fn email ->
      [url] = Regex.run(~r{http://test/confirm/(\S+)}, email.text_body, capture: :all_but_first)
      send(self(), {:confirm_token, url})
      true
    end)

    assert_received {:confirm_token, token}

    assert {:ok, _group, subscription} =
             Newsletters.confirm_subscription(token, fn manage_token ->
               "http://test/manage/#{manage_token}"
             end)

    assert_email_sent(fn _email -> true end)

    subscription
  end

  test "no-op when nobody is due" do
    assert :ok = perform_job(NewsletterDigestWorker, %{})
    refute_email_sent()
  end

  test "delivers to a due subscriber and stamps last_sent_at" do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :public_listed)
    member = group_member_fixture(group)
    drain_delivered_emails()

    subscription = confirmed_subscription!(group, "daily")
    drain_delivered_emails()

    {:ok, _post} = Feed.create_post(member, group, %{"body_markdown" => "Ugens nyt"})
    drain_delivered_emails()

    assert :ok = perform_job(NewsletterDigestWorker, %{})

    assert_email_sent(fn email ->
      assert email.text_body =~ "Ugens nyt"
      true
    end)

    assert Repo.reload!(subscription).last_sent_at
  end
end
