defmodule Kammer.GuestRsvpTest do
  use Kammer.DataCase, async: true
  use Oban.Testing, repo: Kammer.Repo

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Swoosh.TestAssertions

  alias Kammer.Authorization
  alias Kammer.Events
  alias Kammer.Events.EventRsvp
  alias Kammer.Guests
  alias Kammer.Guests.GuestIdentity
  alias Kammer.Repo

  defp guest_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "email" => "gaest#{System.unique_integer([:positive])}@example.org",
        "display_name" => "Gæsten",
        "status" => "yes"
      },
      overrides
    )
  end

  defp public_event_context(visibility \\ :public_listed) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: visibility)
    member = group_member_fixture(group)

    {:ok, event} =
      Events.create_event(member, group, %{
        "title" => "Open concert",
        "starts_at" => DateTime.add(DateTime.utc_now(:second), 72, :hour)
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

  defp request!(event, group, attrs) do
    assert :ok =
             Events.request_guest_rsvp(event, group, attrs,
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
    assert {:ok, event, identity} =
             Events.confirm_guest_rsvp(token, fn manage_token ->
               "http://test/manage/#{manage_token}"
             end)

    assert_email_sent(fn email ->
      [url] = Regex.run(~r{http://test/manage/(\S+)}, email.text_body, capture: :all_but_first)
      send(self(), {:manage_token, url})
      true
    end)

    assert_received {:manage_token, manage_token}
    {event, identity, manage_token}
  end

  describe "capacity and waitlist (issue #318)" do
    test "guests count under the one cap, hear about it, and are promoted by email" do
      %{event: event, group: group, member: member} = public_event_context()
      {:ok, event} = Events.update_event(member, event, %{"capacity" => 1})
      {:ok, _seated} = Events.rsvp(member, event, :yes)

      # The confirm flow records the RSVP as waitlisted, and the
      # confirmation email says so rather than implying a seat.
      token = request!(event, group, guest_attrs())

      assert {:ok, _event, identity} =
               Events.confirm_guest_rsvp(token, fn manage_token -> "manage/#{manage_token}" end)

      rsvp = Repo.get_by!(EventRsvp, event_id: event.id, guest_identity_id: identity.id)
      assert rsvp.status == :waitlisted

      assert_email_sent(fn email ->
        email.subject =~ "Your RSVP" and email.text_body =~ "you're on the waitlist"
      end)

      # The member's cancellation promotes the guest; delivery goes out
      # by email (guests have no notification levels).
      assert {:ok, _freed} = Events.rsvp(member, event, :no)
      assert Repo.reload!(rsvp).status == :yes

      args = %{
        "type" => "event_promotion",
        "event_id" => event.id,
        "guest_identity_id" => identity.id
      }

      assert_enqueued(worker: Kammer.Workers.NotificationFanoutWorker, args: args)
      drain_delivered_emails()
      assert :ok = perform_job(Kammer.Workers.NotificationFanoutWorker, args)

      assert_email_sent(fn email ->
        Enum.any?(email.to, fn {_name, address} -> address == identity.email end) and
          email.subject =~ "A spot opened up" and email.text_body =~ "you're now attending"
      end)
    end
  end

  describe "authorization" do
    test "guest RSVP is exactly the public presets, never archived" do
      {community, _owner} = community_with_owner_fixture()

      for {visibility, allowed?} <- [
            {:private, false},
            {:community, false},
            {:public_link, true},
            {:public_listed, true}
          ] do
        group = group_fixture(community, visibility: visibility)
        assert Authorization.can_guest_rsvp?(group) == allowed?
      end

      archived =
        group_fixture(community, visibility: :public_listed)
        |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
        |> Repo.update!()

      refute Authorization.can_guest_rsvp?(archived)
    end

    test "requests against non-public groups are refused" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :community)
      member = group_member_fixture(group)

      {:ok, event} =
        Events.create_event(member, group, %{
          "title" => "Members only",
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 48, :hour)
        })

      assert {:error, :unauthorized} =
               Events.request_guest_rsvp(event, group, guest_attrs(),
                 client_ip: nil,
                 confirm_url_fun: fn _token -> "unused" end
               )
    end
  end

  describe "the confirm flow" do
    test "records nothing until the emailed link is followed" do
      %{event: event, group: group} = public_event_context()
      attrs = guest_attrs()

      token = request!(event, group, attrs)
      assert Repo.aggregate(GuestIdentity, :count) == 0
      assert Repo.aggregate(EventRsvp, :count) == 0

      {confirmed_event, identity, _manage} = confirm!(token)
      assert confirmed_event.id == event.id
      assert identity.email == attrs["email"]
      assert identity.verified_at

      rsvp = Repo.get_by!(EventRsvp, event_id: event.id, guest_identity_id: identity.id)
      assert rsvp.status == :yes
      assert rsvp.user_id == nil
    end

    test "rejects garbage and expired tokens" do
      assert {:error, :invalid} = Events.confirm_guest_rsvp("garbage", fn _token -> "unused" end)

      # A validly-signed token past the 48-hour confirm window is just
      # as dead. Signed with the same secret/salt `Kammer.Guests.Token`
      # uses, but back-dated beyond the max age.
      %{event: event} = public_event_context()

      expired =
        Plug.Crypto.sign(
          Application.get_env(:kammer, KammerWeb.Endpoint)[:secret_key_base],
          "guest confirm",
          %{
            event_id: event.id,
            email: "forsinket@example.org",
            display_name: "Forsinket",
            status: :yes
          },
          signed_at: System.system_time(:second) - 60 * 60 * 49
        )

      assert {:error, :invalid} = Events.confirm_guest_rsvp(expired, fn _token -> "unused" end)
      assert Repo.aggregate(GuestIdentity, :count) == 0
    end

    test "confirming twice keeps one RSVP with the latest answer" do
      %{event: event, group: group} = public_event_context()

      attrs = guest_attrs()
      {_event, _identity, _manage} = event |> request!(group, attrs) |> confirm!()

      {_event, identity, _manage} =
        event |> request!(group, %{attrs | "status" => "maybe"}) |> confirm!()

      assert [rsvp] = Repo.all(EventRsvp)
      assert rsvp.status == :maybe
      assert rsvp.guest_identity_id == identity.id
    end

    test "validates email shape and rate-limits per email" do
      %{event: event, group: group} = public_event_context()

      assert {:error, %Ecto.Changeset{}} =
               Events.request_guest_rsvp(event, group, guest_attrs(%{"email" => "not an email"}),
                 client_ip: nil,
                 confirm_url_fun: fn _token -> "unused" end
               )

      attrs = guest_attrs()
      for _attempt <- 1..3, do: request!(event, group, attrs)

      assert {:error, :rate_limited} =
               Events.request_guest_rsvp(event, group, attrs,
                 client_ip: nil,
                 confirm_url_fun: fn _token -> "unused" end
               )
    end
  end

  describe "management links" do
    setup do
      context = public_event_context()

      {_event, identity, manage_token} =
        context.event |> request!(context.group, guest_attrs()) |> confirm!()

      Map.merge(context, %{identity: identity, manage_token: manage_token})
    end

    test "load, change, and erase", %{event: event, identity: identity, manage_token: token} do
      assert {:ok, %{identity: loaded_identity, rsvps: [rsvp], comments: []}} =
               Guests.fetch_manage_state(token)

      assert loaded_identity.id == identity.id
      assert rsvp.event.id == event.id
      assert rsvp.status == :yes

      assert {:ok, changed} = Events.update_guest_rsvp(token, event.id, :no)
      assert changed.status == :no

      assert :ok = Guests.erase_by_token(token)
      assert Repo.aggregate(GuestIdentity, :count) == 0
      assert Repo.aggregate(EventRsvp, :count) == 0
      assert {:error, :invalid} = Guests.fetch_manage_state(token)
    end

    test "cannot RSVP to a different event through the manage link", %{manage_token: token} do
      other_context = public_event_context()

      assert {:error, :invalid} =
               Events.update_guest_rsvp(token, other_context.event.id, :yes)
    end
  end

  describe "claiming guest history on sign-in" do
    test "guest RSVPs move to the account with the same email" do
      %{event: event, group: group} = public_event_context()
      {_event, identity, _manage} = event |> request!(group, guest_attrs()) |> confirm!()

      user = user_fixture(email: identity.email)
      assert :ok = Guests.claim_history(user)

      assert Repo.get_by(GuestIdentity, email: identity.email) == nil
      rsvp = Repo.get_by!(EventRsvp, event_id: event.id, user_id: user.id)
      assert rsvp.guest_identity_id == nil
    end

    test "the member's own RSVP wins over the guest one" do
      %{event: event, group: group, member: _member} = public_event_context()
      {_event, identity, _manage} = event |> request!(group, guest_attrs()) |> confirm!()

      user = user_fixture(email: identity.email)
      group_member_fixture_for_user(group, user)
      {:ok, _member_rsvp} = Events.rsvp(user, event, :no)

      assert :ok = Guests.claim_history(user)

      assert [rsvp] = Repo.all(EventRsvp)
      assert rsvp.user_id == user.id
      assert rsvp.status == :no
    end
  end

  defp group_member_fixture_for_user(group, user) do
    {:ok, _membership} = Kammer.Groups.add_member(group, user)
    user
  end
end
