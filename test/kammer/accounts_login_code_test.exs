defmodule Kammer.AccountsLoginCodeTest do
  @moduledoc """
  Short sign-in codes (issue #177): minted alongside the magic link
  for the PWA flow, hashed at rest, single-use, email-scoped, on the
  magic link's 15-minute lifetime — and rate-limited hard enough that
  40 bits of entropy cannot be brute-forced.
  """

  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures

  alias Kammer.Accounts
  alias Kammer.Accounts.UserToken

  @crockford_code ~r/^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{8}$/

  describe "deliver_login_instructions/3 with code: true" do
    test "emails a short code alongside the link, stored hashed and email-scoped" do
      user = unconfirmed_user_fixture()

      {:ok, email} = Accounts.deliver_login_instructions(user, &"[LINK]#{&1}[LINK]", code: true)

      assert [_link_token] =
               Regex.run(~r/\[LINK\]([\w-]+)\[LINK\]/, email.text_body, capture: :all_but_first)

      code = extract_code(email)
      assert code =~ @crockford_code

      assert token_row = Repo.get_by(UserToken, context: "login-code")
      assert token_row.token == :crypto.hash(:sha256, code)
      assert token_row.sent_to == user.email
      assert token_row.user_id == user.id

      assert email.text_body =~
               "The link and code are valid for 15 minutes and can each be used once."
    end

    test "without the option the email carries no code (web flow unchanged)" do
      user = unconfirmed_user_fixture()

      {:ok, email} = Accounts.deliver_login_instructions(user, &"link:#{&1}")

      refute email.text_body =~ "sign-in code"
      refute Repo.get_by(UserToken, context: "login-code")
    end
  end

  describe "exchange_login_code_for_device_token/4" do
    test "exchanges a valid code for a device token and confirms the account" do
      user = unconfirmed_user_fixture()
      {code, _token_row} = mint_login_code(user)

      assert {:ok, device_token, exchanged_user} =
               Accounts.exchange_login_code_for_device_token(user.email, code, "My phone")

      assert exchanged_user.id == user.id
      assert exchanged_user.confirmed_at
      assert Accounts.get_user_by_device_token(device_token).id == user.id
    end

    test "codes are single-use" do
      user = user_fixture()
      {code, _token_row} = mint_login_code(user)

      assert {:ok, _device_token, _user} =
               Accounts.exchange_login_code_for_device_token(user.email, code, nil)

      assert {:error, :not_found} =
               Accounts.exchange_login_code_for_device_token(user.email, code, nil)
    end

    test "an expired code is rejected" do
      user = user_fixture()
      {code, token_row} = mint_login_code(user)
      offset_user_token(token_row.token, -16, :minute)

      assert {:error, :not_found} =
               Accounts.exchange_login_code_for_device_token(user.email, code, nil)
    end

    test "a code cannot be redeemed against a different email" do
      user = user_fixture()
      other_user = user_fixture()
      {code, _token_row} = mint_login_code(user)

      assert {:error, :not_found} =
               Accounts.exchange_login_code_for_device_token(other_user.email, code, nil)

      # Scoped correctly, it still works for its own email.
      assert {:ok, _device_token, _user} =
               Accounts.exchange_login_code_for_device_token(user.email, code, nil)
    end

    test "input is normalized: case-insensitive, lookalikes, separators" do
      user = user_fixture()

      # Find a code that actually contains a 0 or 1 so the lookalike
      # mapping is exercised, not vacuously passed.
      code =
        Enum.find(
          Stream.repeatedly(fn -> build_login_code(user) end) |> Enum.take(100),
          fn code ->
            String.contains?(code, ["0", "1"])
          end
        )

      assert code, "no code with a 0 or 1 in 100 draws — astronomically unlikely"
      insert_login_code(user, code)

      hand_typed =
        code
        |> String.replace("0", "O")
        |> String.replace("1", "l")
        |> String.downcase()
        |> then(fn typed -> String.slice(typed, 0, 4) <> "-" <> String.slice(typed, 4, 4) end)

      assert {:ok, _device_token, _user} =
               Accounts.exchange_login_code_for_device_token(user.email, hand_typed, nil)
    end

    test "first use of the magic link (unconfirmed account) also invalidates the code" do
      user = unconfirmed_user_fixture()
      {code, _token_row} = mint_login_code(user)
      {encoded_token, _hashed} = generate_user_magic_link_token(user)

      assert {:ok, {_user, _expired}} = Accounts.login_user_by_magic_link(encoded_token)

      assert {:error, :not_found} =
               Accounts.exchange_login_code_for_device_token(user.email, code, nil)
    end

    test "five wrong guesses trip the per-email limit — even for a then-correct code" do
      user = user_fixture()
      {code, _token_row} = mint_login_code(user)

      for _attempt <- 1..5 do
        assert {:error, :not_found} =
                 Accounts.exchange_login_code_for_device_token(user.email, "WRONGWRO", nil)
      end

      # The brute-force posture: burning the attempt budget locks out
      # a later correct guess too.
      assert {:error, :rate_limited} =
               Accounts.exchange_login_code_for_device_token(user.email, code, nil)
    end

    test "attempts are rate limited per IP across emails" do
      shared_ip = {203, 0, 113, 42}

      results =
        for attempt <- 1..21 do
          Accounts.exchange_login_code_for_device_token(
            "login-code-probe-#{attempt}@example.org",
            "WRONGWRO",
            nil,
            ip: shared_ip
          )
        end

      assert {:error, :not_found} = List.first(results)
      assert {:error, :rate_limited} = List.last(results)
    end
  end

  defp mint_login_code(user) do
    {code, code_token} = UserToken.build_login_code(user)
    {code, Repo.insert!(code_token)}
  end

  defp build_login_code(user) do
    {code, _code_token} = UserToken.build_login_code(user)
    code
  end

  defp insert_login_code(user, code) do
    Repo.insert!(%UserToken{
      token: :crypto.hash(:sha256, code),
      context: "login-code",
      sent_to: user.email,
      user_id: user.id
    })
  end

  defp extract_code(email) do
    [code] =
      Regex.run(~r/sign-in code in the app:\n\n([0-9A-Z]{8})/, email.text_body,
        capture: :all_but_first
      )

    code
  end
end
