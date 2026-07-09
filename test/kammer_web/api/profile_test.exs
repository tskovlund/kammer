defmodule KammerWeb.Api.ProfileTest do
  @moduledoc """
  The caller's own account over the API (issue #182): base profile
  read/update, per-community custom-field answers (ADR 0020), and
  device management (issue #174) — including the guarantee that
  revoking an API device severs its live sockets, and that one user
  can never see or revoke another's credentials.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Accounts
  alias Kammer.AccountsFixtures
  alias Kammer.Communities

  describe "own profile" do
    test "read/update round-trip; invalid values are refused" do
      user = AccountsFixtures.user_fixture()

      %{"data" => profile} =
        user
        |> api_conn()
        |> get(~p"/api/v1/me")
        |> tap(&assert_operation_response(&1, "me_show"))
        |> json_response(200)

      assert profile["email"] == user.email
      assert profile["contact_phone_visibility"] == "hidden"

      %{"data" => updated} =
        user
        |> api_conn()
        |> put(~p"/api/v1/me", %{
          "display_name" => "Nyt Navn",
          "timezone" => "Europe/Copenhagen",
          "bio" => "Hornist",
          "contact_phone" => "12345678",
          "contact_phone_visibility" => "members"
        })
        |> tap(&assert_operation_response(&1, "me_update"))
        |> json_response(200)

      assert updated["display_name"] == "Nyt Navn"
      assert updated["timezone"] == "Europe/Copenhagen"
      assert updated["contact_phone_visibility"] == "members"

      %{"error" => %{"code" => "invalid_params", "details" => details}} =
        user
        |> api_conn()
        |> put(~p"/api/v1/me", %{"timezone" => "Mars/Olympus_Mons"})
        |> json_response(422)

      assert details["timezone"]

      # A blanked display name is refused — it's the one required field.
      user
      |> api_conn()
      |> put(~p"/api/v1/me", %{"display_name" => ""})
      |> json_response(422)
    end
  end

  describe "community profile" do
    setup do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)
      %{community: community, owner: owner, member: member}
    end

    test "a member sees all fields (their own form) and blanking clears an answer", %{
      community: community,
      owner: owner,
      member: member
    } do
      {:ok, admins_field} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Kostbehov",
          "field_type" => "text",
          "visibility" => "admins"
        })

      path = ~p"/api/v1/communities/#{community.slug}/profile"

      %{"data" => profile} =
        member
        |> api_conn()
        |> get(path)
        |> tap(&assert_operation_response(&1, "community_profile_show"))
        |> json_response(200)

      # Own form: even the admins-visible field appears — it's the
      # member's own answer (ADR 0020 redacts the roster, not this).
      assert Enum.map(profile["fields"], & &1["id"]) == [admins_field.id]

      %{"data" => %{"values" => values}} =
        member
        |> api_conn()
        |> put(path, %{"values" => %{admins_field.id => "Vegetar"}})
        |> json_response(200)

      assert values[admins_field.id] == "Vegetar"

      %{"data" => %{"values" => cleared}} =
        member
        |> api_conn()
        |> put(path, %{"values" => %{admins_field.id => ""}})
        |> json_response(200)

      assert cleared == %{}

      # No membership, no profile — the community itself is public.
      AccountsFixtures.user_fixture() |> api_conn() |> get(path) |> json_response(403)
    end
  end

  describe "devices (#174)" do
    test "lists both credential kinds with the caller flagged; revokes by id" do
      user = AccountsFixtures.user_fixture()
      _session_token = Accounts.generate_user_session_token(user, "Mozilla/5.0 Firefox/128.0")
      caller_token = Accounts.create_device_token(user, "Min telefon")
      other_api_token = Accounts.create_device_token(user, "Gammel tablet")

      %{"data" => devices} =
        caller_token
        |> device_conn()
        |> get(~p"/api/v1/me/devices")
        |> tap(&assert_operation_response(&1, "devices_index"))
        |> json_response(200)

      assert Enum.count(devices) == 3
      assert [current] = Enum.filter(devices, & &1["current"])
      assert %{"kind" => "api_device", "device_name" => "Min telefon"} = current

      assert %{"device_name" => "Mozilla/5.0 Firefox/128.0"} =
               Enum.find(devices, &(&1["kind"] == "session"))

      # Revoking the other API device kills its token and severs its
      # sockets — the #174 guarantee for a lost or stolen device.
      KammerWeb.Endpoint.subscribe("api_user_socket:#{user.id}")
      other = Enum.find(devices, &(&1["device_name"] == "Gammel tablet"))

      caller_token
      |> device_conn()
      |> delete(~p"/api/v1/me/devices/#{other["id"]}")
      |> tap(&assert_operation_response(&1, "devices_revoke"))
      |> json_response(200)

      refute Accounts.get_user_by_device_token(other_api_token)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      # Session revocation works the same way, sans socket broadcast.
      session = Enum.find(devices, &(&1["kind"] == "session"))

      caller_token
      |> device_conn()
      |> delete(~p"/api/v1/me/devices/#{session["id"]}")
      |> json_response(200)

      assert user |> Accounts.list_user_devices() |> Enum.count() == 1
    end

    test "one user can never see or revoke another's devices" do
      user = AccountsFixtures.user_fixture()
      victim = AccountsFixtures.user_fixture()
      victim_token = Accounts.create_device_token(victim, "Offerets telefon")
      [victim_device] = Accounts.list_user_devices(victim)

      %{"data" => devices} =
        user |> api_conn() |> get(~p"/api/v1/me/devices") |> json_response(200)

      refute Enum.any?(devices, &(&1["id"] == victim_device.id))

      user
      |> api_conn()
      |> delete(~p"/api/v1/me/devices/#{victim_device.id}")
      |> json_response(404)

      assert Accounts.get_user_by_device_token(victim_token)
    end

    test "a revoked device token stops authenticating" do
      user = AccountsFixtures.user_fixture()
      token = Accounts.create_device_token(user, "Denne enhed")

      %{"data" => [%{"id" => id, "current" => true}]} =
        token |> device_conn() |> get(~p"/api/v1/me/devices") |> json_response(200)

      token |> device_conn() |> delete(~p"/api/v1/me/devices/#{id}") |> json_response(200)
      token |> device_conn() |> get(~p"/api/v1/me/devices") |> json_response(401)
    end
  end

  defp device_conn(token) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end
end
