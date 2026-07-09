defmodule Kammer.AccountsPasskeyTest do
  @moduledoc """
  Passkeys (ADR 0018, SPEC §16): registration, listing, deletion, and
  usernameless authentication — exercised against the real Wax
  verification path via hand-crafted ceremonies (`WebauthnHelper`).
  """

  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.WebauthnHelper

  alias Kammer.Accounts

  @origin "https://kammer.test"

  describe "registration" do
    test "a valid ceremony stores the credential" do
      user = user_fixture()
      challenge = Accounts.new_passkey_registration_challenge(user, @origin)
      ceremony = registration_ceremony(challenge, @origin)

      assert {:ok, passkey} =
               Accounts.register_passkey(
                 user,
                 ceremony.attestation_object,
                 ceremony.client_data_json,
                 challenge,
                 "My phone"
               )

      assert passkey.user_id == user.id
      assert passkey.credential_id == ceremony.credential_id
      assert passkey.nickname == "My phone"
      assert passkey.sign_count == 0
      assert [%{id: id}] = Accounts.list_passkeys(user)
      assert id == passkey.id
    end

    test "a tampered client data origin is rejected" do
      user = user_fixture()
      challenge = Accounts.new_passkey_registration_challenge(user, @origin)
      ceremony = registration_ceremony(challenge, "https://evil.example")

      assert {:error, _reason} =
               Accounts.register_passkey(
                 user,
                 ceremony.attestation_object,
                 ceremony.client_data_json,
                 challenge
               )

      assert Accounts.list_passkeys(user) == []
    end

    test "the same credential id cannot be registered twice" do
      user = user_fixture()
      challenge = Accounts.new_passkey_registration_challenge(user, @origin)
      ceremony = registration_ceremony(challenge, @origin)

      assert {:ok, _passkey} =
               Accounts.register_passkey(
                 user,
                 ceremony.attestation_object,
                 ceremony.client_data_json,
                 challenge
               )

      other_user = user_fixture()
      other_challenge = Accounts.new_passkey_registration_challenge(other_user, @origin)

      other_ceremony =
        registration_ceremony(other_challenge, @origin, credential_id: ceremony.credential_id)

      assert {:error, %Ecto.Changeset{}} =
               Accounts.register_passkey(
                 other_user,
                 other_ceremony.attestation_object,
                 other_ceremony.client_data_json,
                 other_challenge
               )
    end
  end

  describe "usernameless authentication" do
    setup do
      user = user_fixture()
      challenge = Accounts.new_passkey_registration_challenge(user, @origin)
      ceremony = registration_ceremony(challenge, @origin)

      {:ok, passkey} =
        Accounts.register_passkey(
          user,
          ceremony.attestation_object,
          ceremony.client_data_json,
          challenge
        )

      %{user: user, passkey: passkey, key_pair: ceremony.key_pair}
    end

    test "a valid assertion signs the user in and advances bookkeeping", %{
      user: user,
      key_pair: key_pair
    } do
      challenge = Accounts.new_passkey_authentication_challenge(@origin)

      assertion =
        authentication_ceremony(challenge, @origin, user |> passkey_credential_id(), key_pair,
          sign_count: 7
        )

      assert {:ok, authenticated} =
               Accounts.login_user_by_passkey(
                 assertion.credential_id,
                 assertion.authenticator_data,
                 assertion.signature,
                 assertion.client_data_json,
                 challenge
               )

      assert authenticated.id == user.id
      assert [%{sign_count: 7, last_used_at: %DateTime{}}] = Accounts.list_passkeys(user)
    end

    test "an unknown credential id is rejected", %{key_pair: key_pair} do
      challenge = Accounts.new_passkey_authentication_challenge(@origin)
      unknown_id = :crypto.strong_rand_bytes(32)
      assertion = authentication_ceremony(challenge, @origin, unknown_id, key_pair)

      assert {:error, :not_found} =
               Accounts.login_user_by_passkey(
                 assertion.credential_id,
                 assertion.authenticator_data,
                 assertion.signature,
                 assertion.client_data_json,
                 challenge
               )
    end

    test "a signature from the wrong key is rejected", %{user: user} do
      challenge = Accounts.new_passkey_authentication_challenge(@origin)
      wrong_key_pair = generate_key_pair()

      assertion =
        authentication_ceremony(
          challenge,
          @origin,
          passkey_credential_id(user),
          wrong_key_pair
        )

      assert {:error, _reason} =
               Accounts.login_user_by_passkey(
                 assertion.credential_id,
                 assertion.authenticator_data,
                 assertion.signature,
                 assertion.client_data_json,
                 challenge
               )
    end

    test "a stale sign count never regresses the clone detector's bookkeeping", %{
      user: user,
      key_pair: key_pair
    } do
      challenge = Accounts.new_passkey_authentication_challenge(@origin)
      credential_id = passkey_credential_id(user)

      first =
        authentication_ceremony(challenge, @origin, credential_id, key_pair, sign_count: 5)

      assert {:ok, _user} =
               Accounts.login_user_by_passkey(
                 first.credential_id,
                 first.authenticator_data,
                 first.signature,
                 first.client_data_json,
                 challenge
               )

      replay_challenge = Accounts.new_passkey_authentication_challenge(@origin)

      replay =
        authentication_ceremony(replay_challenge, @origin, credential_id, key_pair, sign_count: 3)

      assert {:ok, _user} =
               Accounts.login_user_by_passkey(
                 replay.credential_id,
                 replay.authenticator_data,
                 replay.signature,
                 replay.client_data_json,
                 replay_challenge
               )

      # WebAuthn §7.2 leaves the stale-count response to the relying
      # party; Kammer deliberately lets the sign-in through (Wax already
      # verified the signature) but the recorded high-water mark must
      # never move backwards — that's the clone detector's whole state.
      assert [%{sign_count: 5}] = Accounts.list_passkeys(user)
    end
  end

  describe "delete_passkey/2" do
    test "removes the passkey, scoped to the owner" do
      user = user_fixture()
      other_user = user_fixture()
      challenge = Accounts.new_passkey_registration_challenge(user, @origin)
      ceremony = registration_ceremony(challenge, @origin)

      {:ok, passkey} =
        Accounts.register_passkey(
          user,
          ceremony.attestation_object,
          ceremony.client_data_json,
          challenge
        )

      assert :ok = Accounts.delete_passkey(other_user, passkey.id)
      assert [_still_there] = Accounts.list_passkeys(user)

      assert :ok = Accounts.delete_passkey(user, passkey.id)
      assert Accounts.list_passkeys(user) == []
    end
  end

  defp passkey_credential_id(user) do
    [passkey] = Accounts.list_passkeys(user)
    passkey.credential_id
  end
end
