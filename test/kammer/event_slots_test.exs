defmodule Kammer.EventSlotsTest do
  @moduledoc """
  Signup slots (issue #37): manager-only slot CRUD, one-tap member
  claims under a capacity lock (the race test proves it never
  overbooks), the guest two-link claim flow, and the SPEC §12 erasure
  and claim-on-sign-in guarantees.
  """

  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Swoosh.TestAssertions

  alias Kammer.Events
  alias Kammer.Events.SlotClaim
  alias Kammer.Guests
  alias Kammer.Guests.GuestIdentity
  alias Kammer.Repo

  defp event_context(group_attrs \\ [visibility: :public_listed]) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, group_attrs)
    creator = group_member_fixture(group)
    member = group_member_fixture(group)

    {:ok, event} =
      Events.create_event(creator, group, %{
        "title" => "Sommerfest",
        "starts_at" => DateTime.add(DateTime.utc_now(:second), 72, :hour)
      })

    drain_delivered_emails()

    %{community: community, group: group, creator: creator, member: member, event: event}
  end

  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end

  defp guest_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "email" => "gaest#{System.unique_integer([:positive])}@example.org",
        "display_name" => "Gæsten"
      },
      overrides
    )
  end

  defp request_claim!(slot, event, group, attrs) do
    assert :ok =
             Events.request_guest_claim(slot, event, group, attrs,
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

  defp confirm_claim!(token) do
    assert {:ok, event, identity} =
             Events.confirm_guest_claim(token, fn manage_token ->
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

  describe "slot management" do
    test "event managers add and delete slots; members cannot" do
      %{creator: creator, member: member, event: event} = event_context()

      assert {:error, :unauthorized} =
               Events.create_slot(member, event, %{"title" => "Kage", "capacity" => "2"})

      assert {:ok, slot} =
               Events.create_slot(creator, event, %{"title" => "Kage", "capacity" => "2"})

      assert slot.position == 0

      assert {:ok, second} =
               Events.create_slot(creator, event, %{"title" => "Kørsel", "capacity" => "4"})

      assert second.position == 1

      assert {:error, %Ecto.Changeset{}} =
               Events.create_slot(creator, event, %{"title" => "", "capacity" => "0"})

      assert {:error, :unauthorized} = Events.delete_slot(member, slot)
      assert {:ok, _deleted} = Events.delete_slot(creator, slot)
    end
  end

  describe "member claims" do
    test "claim, duplicate refused, unclaim; moderators release others" do
      %{creator: creator, member: member, event: event} = event_context()
      {:ok, slot} = Events.create_slot(creator, event, %{"title" => "Kage", "capacity" => "2"})

      assert {:ok, claim} = Events.claim_slot(member, slot)
      assert {:error, %Ecto.Changeset{}} = Events.claim_slot(member, slot)

      other = user_fixture()
      assert {:error, :unauthorized} = Events.claim_slot(other, slot)
      assert {:error, :unauthorized} = Events.unclaim_slot(other, claim)

      assert {:ok, _released} = Events.unclaim_slot(member, claim)

      assert {:ok, claim_again} = Events.claim_slot(member, slot)
      # The creator manages the event, so they may release anyone.
      assert {:ok, _released} = Events.unclaim_slot(creator, claim_again)
    end

    test "capacity is enforced — including under concurrency" do
      %{creator: creator, group: group, event: event} = event_context()
      {:ok, slot} = Events.create_slot(creator, event, %{"title" => "Kage", "capacity" => "1"})

      contenders = for _n <- 1..4, do: group_member_fixture(group)
      parent = self()

      results =
        contenders
        |> Enum.map(fn user ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            Events.claim_slot(user, slot)
          end)
        end)
        |> Task.await_many(:infinity)

      assert Enum.count(results, &match?({:ok, _claim}, &1)) == 1
      assert Enum.count(results, &match?({:error, :slot_full}, &1)) == 3
      assert Repo.aggregate(SlotClaim, :count) == 1
    end
  end

  describe "guest claims" do
    test "the two-link flow records nothing until confirmed" do
      %{creator: creator, group: group, event: event} = event_context()
      {:ok, slot} = Events.create_slot(creator, event, %{"title" => "Kage", "capacity" => "2"})

      token = request_claim!(slot, event, group, guest_attrs())
      assert Repo.aggregate(GuestIdentity, :count) == 0
      assert Repo.aggregate(SlotClaim, :count) == 0

      {confirmed_event, identity, manage_token} = confirm_claim!(token)
      assert confirmed_event.id == event.id
      assert identity.verified_at

      claim = Repo.get_by!(SlotClaim, guest_identity_id: identity.id)
      assert claim.slot_id == slot.id

      # The manage page lists it and releases it.
      assert {:ok, %{claims: [listed]}} = Guests.fetch_manage_state(manage_token)
      assert listed.slot.event.id == event.id

      assert {:ok, _released} = Events.unclaim_slot_by_token(manage_token, claim.id)
      assert Repo.aggregate(SlotClaim, :count) == 0
    end

    test "non-public groups refuse; a full slot refuses at request and confirm" do
      %{creator: creator, group: group, member: member, event: event} = event_context()
      {:ok, slot} = Events.create_slot(creator, event, %{"title" => "Kage", "capacity" => "1"})

      private_context = event_context(visibility: :community)

      {:ok, private_slot} =
        Events.create_slot(private_context.creator, private_context.event, %{
          "title" => "Lukket",
          "capacity" => "1"
        })

      assert {:error, :unauthorized} =
               Events.request_guest_claim(
                 private_slot,
                 private_context.event,
                 private_context.group,
                 guest_attrs(),
                 client_ip: nil,
                 confirm_url_fun: fn _token -> "unused" end
               )

      # Take the token first, then fill the slot: confirm must refuse.
      token = request_claim!(slot, event, group, guest_attrs())
      {:ok, _claim} = Events.claim_slot(member, slot)

      assert {:error, :slot_full} =
               Events.confirm_guest_claim(token, fn _manage -> "unused" end)

      assert {:error, :slot_full} =
               Events.request_guest_claim(slot, event, group, guest_attrs(),
                 client_ip: nil,
                 confirm_url_fun: fn _token -> "unused" end
               )
    end

    test "erasure removes claims; sign-in claims them" do
      %{creator: creator, group: group, event: event} = event_context()
      {:ok, slot} = Events.create_slot(creator, event, %{"title" => "Kage", "capacity" => "3"})

      # Erasure path.
      {_event, _identity, manage_token} =
        slot |> request_claim!(event, group, guest_attrs()) |> confirm_claim!()

      assert :ok = Guests.erase_by_token(manage_token)
      assert Repo.aggregate(SlotClaim, :count) == 0
      assert Repo.aggregate(GuestIdentity, :count) == 0

      # Claim-on-sign-in path.
      {_event, identity, _manage} =
        slot |> request_claim!(event, group, guest_attrs()) |> confirm_claim!()

      user = user_fixture(email: identity.email)
      assert :ok = Guests.claim_history(user)

      claim = Repo.get_by!(SlotClaim, slot_id: slot.id)
      assert claim.user_id == user.id
      assert claim.guest_identity_id == nil
      assert Repo.aggregate(GuestIdentity, :count) == 0
    end
  end
end
