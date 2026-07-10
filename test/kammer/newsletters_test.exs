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
  alias Kammer.Guests.Token, as: GuestToken
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

  describe "one-click unsubscribe scoping (issue #233)" do
    test "the List-Unsubscribe token is scoped to its own subscription, not the full-power manage token" do
      %{group: group, member: member} = public_group_context()
      {_group, subscription, manage_token} = group |> request!(subscribe_attrs()) |> confirm!()

      drain_delivered_emails()

      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Nyt indlæg!"})
      assert :ok = Newsletters.notify_subscribers(post)

      assert_email_sent(fn email ->
        [token] =
          Regex.run(~r{/newsletter/unsubscribe/(\S+)>}, email.headers["List-Unsubscribe"],
            capture: :all_but_first
          )

        send(self(), {:header_token, token})
        true
      end)

      assert_received {:header_token, header_token}

      # It's a different token than the manage link carries...
      refute header_token == manage_token
      # ...verifying under a different salt, to exactly the subscription
      # it was minted for...
      assert {:ok, %{subscription_id: id}} = GuestToken.verify_unsubscribe(header_token)
      assert id == subscription.id
      # ...and it is powerless against the manage surface — every manage
      # endpoint gates on this same check.
      refute Guests.manage_token_valid?(header_token)

      # It does what it's scoped to do.
      assert :ok = Newsletters.unsubscribe_by_scoped_token(header_token)
      assert Repo.aggregate(NewsletterSubscription, :count) == 0
    end

    test "a scoped token only ever unsubscribes the subscription named inside it" do
      %{group: group} = public_group_context()
      {_group, subscription_a, _manage} = group |> request!(subscribe_attrs()) |> confirm!()
      {_group, subscription_b, _manage} = group |> request!(subscribe_attrs()) |> confirm!()

      # No separate id travels alongside the token for an attacker to
      # vary — the subscription it names is baked into the signed
      # payload itself.
      token = GuestToken.sign_unsubscribe(%{subscription_id: subscription_a.id})

      assert :ok = Newsletters.unsubscribe_by_scoped_token(token)
      assert Repo.get(NewsletterSubscription, subscription_a.id) == nil
      assert Repo.get(NewsletterSubscription, subscription_b.id) != nil
    end

    test "an invalid, garbage, or cross-purpose token is one neutral :invalid, never an oracle" do
      %{group: group} = public_group_context()
      {_group, subscription, _manage} = group |> request!(subscribe_attrs()) |> confirm!()
      manage_token = GuestToken.sign_manage(%{identity_id: subscription.guest_identity_id})

      assert {:error, :invalid} = Newsletters.unsubscribe_by_scoped_token("garbage")
      # The manage token doesn't verify here either — different salt,
      # so a leaked manage token can't be replayed as an unsubscribe
      # token any more than the reverse.
      assert {:error, :invalid} = Newsletters.unsubscribe_by_scoped_token(manage_token)
    end

    test "a duplicate fetch of the same token is a neutral no-op, never a crash" do
      %{group: group} = public_group_context()
      {_group, subscription, _manage} = group |> request!(subscribe_attrs()) |> confirm!()
      token = GuestToken.sign_unsubscribe(%{subscription_id: subscription.id})

      assert :ok = Newsletters.unsubscribe_by_scoped_token(token)
      # Mail gateways auto-fetch (and may pre-fetch or retry) the
      # `List-Unsubscribe` POST with no human in the loop, so a second
      # delivery of the same token must stay `:ok` rather than raise on
      # the already-deleted row — the endpoint's contract is to always
      # answer 200.
      assert :ok = Newsletters.unsubscribe_by_scoped_token(token)
      assert Repo.aggregate(NewsletterSubscription, :count) == 0
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
