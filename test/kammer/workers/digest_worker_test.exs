defmodule Kammer.Workers.DigestWorkerTest do
  @moduledoc """
  Worker-level coverage for the digest tick (SPEC §16) — that
  `perform/1` actually drives `Digests.due_users/1` and
  `Digests.deliver_digest/2` end to end via `perform_job/2`. Cadence
  math and email content are covered in depth by `Kammer.DigestsTest`.
  """

  use Kammer.DataCase, async: true
  use Oban.Testing, repo: Kammer.Repo

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Swoosh.TestAssertions

  alias Kammer.Feed
  alias Kammer.Repo
  alias Kammer.Workers.DigestWorker

  defp set_frequency(user, frequency) do
    user
    |> Ecto.Changeset.change(digest_frequency: frequency)
    |> Repo.update!()
  end

  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end

  test "no-op when nobody is due — a user with digests off never appears" do
    user_fixture() |> set_frequency(:off)
    drain_delivered_emails()

    assert :ok = perform_job(DigestWorker, %{})
    refute_email_sent()
  end

  test "delivers to a due user and stamps last_digest_at" do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    author = group_member_fixture(group)
    me = group_member_fixture(group) |> set_frequency(:daily)

    {:ok, _post} = Feed.create_post(author, group, %{"body_markdown" => "Dagens nyt"})
    drain_delivered_emails()

    assert :ok = perform_job(DigestWorker, %{})

    assert_email_sent(fn email ->
      assert email.text_body =~ "Dagens nyt"
      true
    end)

    assert Repo.reload!(me).last_digest_at
  end
end
