defmodule Kammer.NewslettersTest do
  @moduledoc """
  Newsletter subscriptions end to end (SPEC §8, ADR 0013 extended):
  the two-link confirm flow, cadence choice, digest delivery cadence
  math, per-post delivery, and one-click unsubscribe.
  """

  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Swoosh.TestAssertions

  alias Kammer.Authorization
  alias Kammer.Feed
  alias Kammer.Guests
  alias Kammer.Guests.GuestIdentity
  alias Kammer.Newsletters
  alias Kammer.Newsletters.NewsletterSubscription
  alias Kammer.Repo

  # A Monday and a Tuesday, both 06:00 UTC — same fixture dates as digests_test.exs.
  @monday ~U[2026-07-06 06:00:00Z]
  @tuesday ~U[2026-07-07 06:00:00Z]

  defp subscribe_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "email" => "foelger#{System.unique_integer([:positive])}@example.org",
        "display_name" => "Følger",
        "cadence" => "per_post"
      },
      overrides
    )
  end

  defp public_group_context(group_attrs \\ []) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, Keyword.merge([visibility: :public_listed], group_attrs))
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

  defp request!(group, attrs) do
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
    token
  end

  defp confirm!(token) do
    assert {:ok, group, subscription} =
             Newsletters.confirm_subscription(token, fn manage_token ->
               "http://test/manage/#{manage_token}"
             end)

    assert_email_sent(fn email ->
      [url] = Regex.run(~r{http://test/manage/(\S+)}, email.text_body, capture: :all_but_first)
      send(self(), {:manage_token, url})
      true
    end)

    assert_received {:manage_token, manage_token}
    {group, subscription, manage_token}
  end

  describe "authorization" do
    test "guest subscriptions need a public, live group" do
      {community, _owner} = community_with_owner_fixture()

      for {attrs, allowed?} <- [
            {[visibility: :public_listed], true},
            {[visibility: :public_link], true},
            {[visibility: :community], false},
            {[visibility: :private], false}
          ] do
        group = group_fixture(community, attrs)
        assert Authorization.can_guest_subscribe?(group) == allowed?
      end

      archived =
        community
        |> group_fixture(visibility: :public_listed)
        |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
        |> Repo.update!()

      refute Authorization.can_guest_subscribe?(archived)
    end

    test "requests against non-public groups are refused" do
      %{group: group} = public_group_context(visibility: :community)

      assert {:error, :unauthorized} =
               Newsletters.request_subscription(group, subscribe_attrs(),
                 client_ip: nil,
                 confirm_url_fun: fn _token -> "unused" end
               )
    end
  end

  describe "the confirm flow" do
    test "records nothing until the emailed link is followed" do
      %{group: group} = public_group_context()
      attrs = subscribe_attrs()

      token = request!(group, attrs)
      assert Repo.aggregate(GuestIdentity, :count) == 0
      assert Repo.aggregate(NewsletterSubscription, :count) == 0

      {confirmed_group, subscription, _manage} = confirm!(token)
      assert confirmed_group.id == group.id
      assert subscription.cadence == :per_post

      identity = Repo.get_by!(GuestIdentity, email: attrs["email"])
      assert identity.verified_at
      assert subscription.guest_identity_id == identity.id
    end

    test "re-confirming the same email updates cadence instead of duplicating" do
      %{group: group} = public_group_context()
      attrs = subscribe_attrs()

      {_group, subscription, _manage} = group |> request!(attrs) |> confirm!()
      assert subscription.cadence == :per_post

      {_group, updated, _manage} =
        group
        |> request!(subscribe_attrs(%{"email" => attrs["email"], "cadence" => "weekly"}))
        |> confirm!()

      assert updated.id == subscription.id
      assert updated.cadence == :weekly
      assert Repo.aggregate(NewsletterSubscription, :count) == 1
    end

    test "rejects garbage tokens and validates the request" do
      %{group: group} = public_group_context()

      assert {:error, :invalid} =
               Newsletters.confirm_subscription("garbage", fn _token -> "unused" end)

      assert {:error, %Ecto.Changeset{}} =
               Newsletters.request_subscription(
                 group,
                 subscribe_attrs(%{"email" => "not an email"}),
                 client_ip: nil,
                 confirm_url_fun: fn _token -> "unused" end
               )
    end

    test "rate-limits per email" do
      %{group: group} = public_group_context()
      attrs = subscribe_attrs()

      for _attempt <- 1..3, do: request!(group, attrs)

      assert {:error, :rate_limited} =
               Newsletters.request_subscription(group, attrs,
                 client_ip: nil,
                 confirm_url_fun: fn _token -> "unused" end
               )
    end
  end

  describe "management" do
    test "the manage link lists the subscription; cadence change and unsubscribe both work" do
      %{group: group} = public_group_context()
      {_group, subscription, manage_token} = group |> request!(subscribe_attrs()) |> confirm!()

      assert {:ok, %{subscriptions: [loaded]}} = Guests.fetch_manage_state(manage_token)
      assert loaded.id == subscription.id

      assert {:ok, updated} = Newsletters.update_cadence(manage_token, subscription.id, :daily)
      assert updated.cadence == :daily

      assert :ok = Newsletters.unsubscribe_by_token(manage_token, subscription.id)
      assert Repo.aggregate(NewsletterSubscription, :count) == 0

      assert {:error, :invalid} = Newsletters.unsubscribe_by_token(manage_token, subscription.id)
    end

    test "signing in with the guest's email removes the subscription (cascade)" do
      %{group: group} = public_group_context()
      attrs = subscribe_attrs()
      {_group, _subscription, _manage} = group |> request!(attrs) |> confirm!()

      identity = Repo.get_by!(GuestIdentity, email: attrs["email"])
      user = user_fixture(email: identity.email)
      assert :ok = Guests.claim_history(user)

      assert Repo.get_by(GuestIdentity, email: identity.email) == nil
      assert Repo.aggregate(NewsletterSubscription, :count) == 0
    end
  end

  describe "per-post delivery" do
    test "notify_subscribers emails only per_post subscribers, with a one-click unsubscribe header" do
      %{group: group, member: member} = public_group_context()
      {_group, _subscription, _manage} = group |> request!(subscribe_attrs()) |> confirm!()

      daily_attrs = subscribe_attrs(%{"cadence" => "daily"})
      {_group, _daily_subscription, _manage} = group |> request!(daily_attrs) |> confirm!()

      drain_delivered_emails()

      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Nyt indlæg!"})
      assert :ok = Newsletters.notify_subscribers(post)

      assert_email_sent(fn email ->
        assert email.text_body =~ "Nyt indlæg!"
        assert email.headers["List-Unsubscribe"] =~ "/newsletter/unsubscribe/"
        assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
        true
      end)

      # Only the per_post subscriber gets the immediate email — the
      # daily subscriber waits for the digest tick, so the mailbox is
      # empty after draining the one expected message above.
      refute_email_sent()
    end
  end

  describe "due_subscriptions/1" do
    test "daily is due daily, weekly only on Mondays" do
      %{group: group} = public_group_context()

      {_g, daily, _m} = group |> request!(subscribe_attrs(%{"cadence" => "daily"})) |> confirm!()

      {_g, weekly, _m} =
        group |> request!(subscribe_attrs(%{"cadence" => "weekly"})) |> confirm!()

      monday_ids = @monday |> Newsletters.due_subscriptions() |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.member?(monday_ids, daily.id)
      assert MapSet.member?(monday_ids, weekly.id)

      tuesday_ids =
        @tuesday |> Newsletters.due_subscriptions() |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.member?(tuesday_ids, daily.id)
      refute MapSet.member?(tuesday_ids, weekly.id)
    end

    test "a recent send guards against double sends" do
      %{group: group} = public_group_context()

      {_g, recent, _m} = group |> request!(subscribe_attrs(%{"cadence" => "daily"})) |> confirm!()

      recent
      |> Ecto.Changeset.change(last_sent_at: DateTime.add(@tuesday, -2, :hour))
      |> Repo.update!()

      {_g, long_ago, _m} =
        group |> request!(subscribe_attrs(%{"cadence" => "daily"})) |> confirm!()

      long_ago
      |> Ecto.Changeset.change(last_sent_at: DateTime.add(@tuesday, -30, :hour))
      |> Repo.update!()

      due_ids = @tuesday |> Newsletters.due_subscriptions() |> Enum.map(& &1.id) |> MapSet.new()
      refute MapSet.member?(due_ids, recent.id)
      assert MapSet.member?(due_ids, long_ago.id)
    end
  end

  describe "deliver_digest/2" do
    test "summarizes only fresh posts, then stamps last_sent_at" do
      %{group: group, member: member} = public_group_context()

      {_g, subscription, _m} =
        group |> request!(subscribe_attrs(%{"cadence" => "weekly"})) |> confirm!()

      {:ok, _post} = Feed.create_post(member, group, %{"body_markdown" => "Ugens nyheder"})
      drain_delivered_emails()

      now = DateTime.utc_now(:second)
      assert :sent = Newsletters.deliver_digest(subscription, now)

      assert_email_sent(fn email ->
        assert email.text_body =~ "Ugens nyheder"
        true
      end)

      assert Repo.reload!(subscription).last_sent_at
    end

    test "an empty period sends nothing but still counts as covered" do
      %{group: group} = public_group_context()

      {_g, subscription, _m} =
        group |> request!(subscribe_attrs(%{"cadence" => "weekly"})) |> confirm!()

      drain_delivered_emails()

      now = DateTime.utc_now(:second)
      assert :skipped = Newsletters.deliver_digest(subscription, now)
      refute_email_sent()
      assert Repo.reload!(subscription).last_sent_at
    end
  end
end
