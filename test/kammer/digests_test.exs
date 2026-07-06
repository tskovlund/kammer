defmodule Kammer.DigestsTest do
  @moduledoc """
  Email digests (SPEC §16): opt-in scheduling (daily every day, weekly
  on Mondays, double-send guarded), content limited to the user's own
  groups, and the no-hollow-email rule.
  """

  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Swoosh.TestAssertions

  alias Kammer.Digests
  alias Kammer.Events
  alias Kammer.Feed
  alias Kammer.Repo

  # A Monday and a Tuesday, both 06:00 UTC.
  @monday ~U[2026-07-06 06:00:00Z]
  @tuesday ~U[2026-07-07 06:00:00Z]

  defp set_frequency(user, frequency, last_digest_at \\ nil) do
    user
    |> Ecto.Changeset.change(digest_frequency: frequency, last_digest_at: last_digest_at)
    |> Repo.update!()
  end

  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end

  describe "due_users/1" do
    test "daily is due daily, weekly only on Mondays, off never" do
      daily = set_frequency(user_fixture(), :daily)
      weekly = set_frequency(user_fixture(), :weekly)
      off = set_frequency(user_fixture(), :off)

      monday_ids = @monday |> Digests.due_users() |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.member?(monday_ids, daily.id)
      assert MapSet.member?(monday_ids, weekly.id)
      refute MapSet.member?(monday_ids, off.id)

      tuesday_ids = @tuesday |> Digests.due_users() |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.member?(tuesday_ids, daily.id)
      refute MapSet.member?(tuesday_ids, weekly.id)
    end

    test "a recent digest guards against double sends" do
      recently_sent =
        set_frequency(user_fixture(), :daily, DateTime.add(@tuesday, -2, :hour))

      long_ago =
        set_frequency(user_fixture(), :daily, DateTime.add(@tuesday, -30, :hour))

      due_ids = @tuesday |> Digests.due_users() |> Enum.map(& &1.id) |> MapSet.new()
      refute MapSet.member?(due_ids, recently_sent.id)
      assert MapSet.member?(due_ids, long_ago.id)
    end
  end

  describe "deliver_digest/2" do
    test "summarizes only the user's groups, and only fresh content" do
      {community, _owner} = community_with_owner_fixture()
      my_group = group_fixture(community)
      other_group = group_fixture(community)

      me = set_frequency(group_member_fixture(my_group), :daily)
      author = group_member_fixture(my_group)
      stranger = group_member_fixture(other_group)

      {:ok, _mine} =
        Feed.create_post(author, my_group, %{"body_markdown" => "Nyt fra min gruppe"})

      {:ok, _foreign} =
        Feed.create_post(stranger, other_group, %{"body_markdown" => "Fremmed indhold"})

      {:ok, _event} =
        Events.create_event(author, my_group, %{
          "title" => "Onsdagsprøve",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
        })

      drain_delivered_emails()

      now = DateTime.utc_now(:second)
      assert :sent = Digests.deliver_digest(me, now)

      assert_email_sent(fn email ->
        assert email.text_body =~ "Nyt fra min gruppe"
        refute email.text_body =~ "Fremmed indhold"
        assert email.text_body =~ "Onsdagsprøve"
        true
      end)

      assert Repo.reload!(me).last_digest_at
    end

    test "an empty period sends nothing but still counts as covered" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      me = set_frequency(group_member_fixture(group), :daily)

      drain_delivered_emails()

      now = DateTime.utc_now(:second)
      assert :skipped = Digests.deliver_digest(me, now)
      refute_email_sent()
      assert Repo.reload!(me).last_digest_at
    end

    test "your own posts don't come back at you" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      me = set_frequency(group_member_fixture(group), :daily)

      {:ok, _post} = Feed.create_post(me, group, %{"body_markdown" => "Mit eget opslag"})
      drain_delivered_emails()

      assert :skipped = Digests.deliver_digest(me, DateTime.utc_now(:second))
    end
  end
end
