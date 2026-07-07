defmodule Kammer.AccountsTest do
  use Kammer.DataCase

  alias Kammer.Accounts

  import Kammer.AccountsFixtures
  alias Kammer.Accounts.{User, UserToken}

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!("11111111-1111-1111-1111-111111111111")
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "register_user/1" do
    test "requires email and display name to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{email: ["can't be blank"], display_name: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_user(%{email: "not valid", display_name: "Someone"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_user(%{email: too_long, display_name: "Someone"})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()
      {:error, changeset} = Accounts.register_user(%{email: email, display_name: "Someone"})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} =
        Accounts.register_user(%{email: String.upcase(email), display_name: "Someone"})

      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers unconfirmed users" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(valid_user_attributes(email: email))
      assert user.email == email
      assert is_nil(user.confirmed_at)
    end

    test "is rate limited per IP across different emails" do
      shared_ip = {203, 0, 113, 8}

      results =
        for _attempt <- 1..11 do
          Accounts.register_user(valid_user_attributes(), ip: shared_ip)
        end

      assert {:error, :rate_limited} = List.last(results)
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %User{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%User{})
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_user_email(user, token)
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_user_email(user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given user in new token", %{user: user} do
      user = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at == user.authenticated_at
      assert DateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert session_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "get_user_by_magic_link_token/1" do
    setup do
      user = user_fixture()
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      %{user: user, token: encoded_token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_magic_link_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_magic_link_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_magic_link_token(token)
    end
  end

  describe "login_user_by_magic_link/1" do
    test "confirms user and expires tokens" do
      user = unconfirmed_user_fixture()
      refute user.confirmed_at
      session_token = Accounts.generate_user_session_token(user)
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, expired_tokens}} = Accounts.login_user_by_magic_link(encoded_token)

      expired_token_values = expired_tokens |> Enum.map(& &1.token) |> Enum.sort()
      assert expired_token_values == Enum.sort([hashed_token, session_token])
      assert user.confirmed_at
    end

    test "returns user and (deleted) token for confirmed user" do
      user = user_fixture()
      assert user.confirmed_at
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      assert {:ok, {^user, []}} = Accounts.login_user_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(encoded_token)
    end
  end

  describe "update_user_settings/2" do
    test "updates display name, locale, and timezone" do
      user = user_fixture()

      assert {:ok, updated_user} =
               Accounts.update_user_settings(user, %{
                 display_name: "New Name",
                 locale: "da",
                 timezone: "Europe/Copenhagen"
               })

      assert updated_user.display_name == "New Name"
      assert updated_user.locale == "da"
      assert updated_user.timezone == "Europe/Copenhagen"
    end

    test "rejects unknown locale and timezone" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.update_user_settings(user, %{locale: "xx", timezone: "Nowhere/Nowhere"})

      assert %{locale: ["is invalid"], timezone: ["is not a known time zone"]} =
               errors_on(changeset)
    end

    test "rejects a blank display name" do
      user = user_fixture()

      assert {:error, changeset} = Accounts.update_user_settings(user, %{display_name: "  "})
      assert "can't be blank" in errors_on(changeset).display_name
    end

    test "updates bio, pronouns, and contact fields with their visibility" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_user_settings(user, %{
                 bio: "Plays the oboe.",
                 pronouns: "she/her",
                 contact_phone: "+45 12345678",
                 contact_phone_visibility: "members"
               })

      assert updated.bio == "Plays the oboe."
      assert updated.pronouns == "she/her"
      assert updated.contact_phone == "+45 12345678"
      assert updated.contact_phone_visibility == :members
    end
  end

  describe "visible_contact_fields/2 (SPEC §4)" do
    test "hidden fields never appear, regardless of role" do
      user =
        user_fixture()
        |> Ecto.Changeset.change(contact_phone: "12345678", contact_phone_visibility: :hidden)
        |> Kammer.Repo.update!()

      assert Accounts.visible_contact_fields(user, :owner) == []
      assert Accounts.visible_contact_fields(user, nil) == []
    end

    test "members-visibility fields show to any member but not outsiders" do
      user =
        user_fixture()
        |> Ecto.Changeset.change(
          contact_email: "oboe@example.com",
          contact_email_visibility: :members
        )
        |> Kammer.Repo.update!()

      assert Accounts.visible_contact_fields(user, :member) == [{:email, "oboe@example.com"}]
      assert Accounts.visible_contact_fields(user, :admin) == [{:email, "oboe@example.com"}]
      assert Accounts.visible_contact_fields(user, nil) == []
    end

    test "admins-visibility fields hide from plain members" do
      user =
        user_fixture()
        |> Ecto.Changeset.change(
          contact_note: "Allergic to peanuts",
          contact_note_visibility: :admins
        )
        |> Kammer.Repo.update!()

      assert Accounts.visible_contact_fields(user, :admin) == [{:note, "Allergic to peanuts"}]
      assert Accounts.visible_contact_fields(user, :member) == []
    end

    test "blank values never appear even when visibility allows them" do
      user =
        user_fixture()
        |> Ecto.Changeset.change(contact_phone_visibility: :members)
        |> Kammer.Repo.update!()

      assert Accounts.visible_contact_fields(user, :member) == []
    end
  end

  describe "sessions and devices" do
    test "list_user_sessions/1 returns only the user's session tokens" do
      user = user_fixture()
      other_user = user_fixture()
      token = Accounts.generate_user_session_token(user, "AgentSmith/1.0")
      _other_token = Accounts.generate_user_session_token(other_user)

      assert [session] = Accounts.list_user_sessions(user)
      assert session.token == token
      assert session.user_agent == "AgentSmith/1.0"
    end

    test "revoke_user_session/2 deletes the session" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      [session] = Accounts.list_user_sessions(user)

      assert :ok = Accounts.revoke_user_session(user, session.id)
      refute Accounts.get_user_by_session_token(token)
    end

    test "revoke_user_session/2 cannot revoke another user's session" do
      user = user_fixture()
      other_user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      [session] = Accounts.list_user_sessions(user)

      assert :ok = Accounts.revoke_user_session(other_user, session.id)
      assert Accounts.get_user_by_session_token(token)
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "login"
    end

    test "is rate limited per email", %{user: user} do
      url_fun = &"http://localhost/log-in/#{&1}"

      for _attempt <- 1..3 do
        assert {:ok, _email} = Accounts.deliver_login_instructions(user, url_fun)
      end

      assert {:error, :rate_limited} = Accounts.deliver_login_instructions(user, url_fun)
    end

    test "is rate limited per IP across different emails" do
      url_fun = &"http://localhost/log-in/#{&1}"
      shared_ip = {203, 0, 113, 7}

      results =
        for _attempt <- 1..11 do
          user = unconfirmed_user_fixture()
          Accounts.deliver_login_instructions(user, url_fun, ip: shared_ip)
        end

      assert {:error, :rate_limited} = List.last(results)
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include tokens or other redacted data" do
      user = %User{email: "someone@example.com", display_name: "Someone"}
      assert inspect(user) =~ "someone@example.com"
    end
  end
end
