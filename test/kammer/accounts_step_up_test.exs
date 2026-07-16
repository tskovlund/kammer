defmodule Kammer.AccountsStepUpTest do
  @moduledoc """
  Step-up re-auth state and its email round-trip (issue #294, ADR
  0029): the stepped-up window on a device-token row, and the
  single-use "step-up" token that ONLY sets it — never the
  account-confirming, everything-expiring semantics of the login
  consumption path.
  """

  use Kammer.DataCase, async: true

  import Ecto.Query
  import Kammer.AccountsFixtures

  alias Kammer.Accounts
  alias Kammer.Accounts.UserToken

  describe "device_stepped_up?/1" do
    test "true within the window, false when stale, never, or absent" do
      user = user_fixture()
      device = device_row(user)

      refute Accounts.device_stepped_up?(device)
      refute Accounts.device_stepped_up?(nil)

      stepped_up = Accounts.step_up_device(device)
      assert Accounts.device_stepped_up?(stepped_up)

      # One second past the configured window (default 10 minutes) is
      # stale — the boundary, not some comfortable margin.
      stale_at =
        DateTime.add(
          DateTime.utc_now(:second),
          -(Kammer.Config.step_up_validity_minutes() * 60 + 1),
          :second
        )

      stale = %{stepped_up | stepped_up_at: stale_at}
      refute Accounts.device_stepped_up?(stale)
    end
  end

  describe "deliver_step_up_instructions/4 + confirm_step_up/1" do
    test "the emailed token steps up exactly the targeted row, once, and nothing else" do
      user = user_fixture()
      target = device_row(user)
      bystander = device_row(user)
      other_tokens_before = token_ids(user)

      {:ok, email} = Accounts.deliver_step_up_instructions(user, target, &"[LINK]#{&1}[LINK]")

      [token] = Regex.run(~r/\[LINK\]([\w-]+)\[LINK\]/, email.text_body, capture: :all_but_first)

      # Stored hashed, bound to the account address and the target row.
      assert row = Repo.get_by(UserToken, context: "step-up")
      assert row.sent_to == user.email
      assert row.target_token_id == target.id

      assert {:ok, %UserToken{id: stepped_id}} = Accounts.confirm_step_up(token)
      assert stepped_id == target.id

      assert Accounts.device_stepped_up?(Repo.get!(UserToken, target.id))
      refute Accounts.device_stepped_up?(Repo.get!(UserToken, bystander.id))

      # Unlike consume_login_token/1: no other token was expired, and
      # the account's confirmed state is untouched.
      assert token_ids(user) == other_tokens_before
      assert Repo.get!(Kammer.Accounts.User, user.id).confirmed_at

      # Single-use: the second confirm is the same neutral not-found.
      assert {:error, :not_found} = Accounts.confirm_step_up(token)
    end

    test "does not confirm an unconfirmed account (not the login consumption path)" do
      user = unconfirmed_user_fixture()
      device = device_row(user)

      {:ok, email} = Accounts.deliver_step_up_instructions(user, device, &"[LINK]#{&1}[LINK]")
      [token] = Regex.run(~r/\[LINK\]([\w-]+)\[LINK\]/, email.text_body, capture: :all_but_first)

      assert {:ok, _device} = Accounts.confirm_step_up(token)
      refute Repo.get!(Kammer.Accounts.User, user.id).confirmed_at
    end

    test "an expired token is refused at the 15-minute boundary" do
      user = user_fixture()
      device = device_row(user)

      {:ok, email} = Accounts.deliver_step_up_instructions(user, device, &"[LINK]#{&1}[LINK]")
      [token] = Regex.run(~r/\[LINK\]([\w-]+)\[LINK\]/, email.text_body, capture: :all_but_first)

      row = Repo.get_by(UserToken, context: "step-up")
      offset_user_token(row.token, -16, :minute)

      assert {:error, :not_found} = Accounts.confirm_step_up(token)
      refute Accounts.device_stepped_up?(Repo.get!(UserToken, device.id))
    end

    test "revoking the targeted device kills its pending step-up link" do
      user = user_fixture()
      device = device_row(user)

      {:ok, email} = Accounts.deliver_step_up_instructions(user, device, &"[LINK]#{&1}[LINK]")
      [token] = Regex.run(~r/\[LINK\]([\w-]+)\[LINK\]/, email.text_body, capture: :all_but_first)

      {:ok, _revoked} = Accounts.revoke_user_device(user, device.id)

      # The FK cascade removed the step-up row with its target — the
      # link cannot outlive the credential it would have elevated.
      refute Repo.get_by(UserToken, context: "step-up")
      assert {:error, :not_found} = Accounts.confirm_step_up(token)
    end

    test "shares the magic-link email budget" do
      user = user_fixture()
      device = device_row(user)

      # The magic-link limiter allows 3 per address per 15 minutes, and
      # the fixture's own sign-in email already spent the first —
      # sharing the budget means sharing it.
      for _request <- 1..2 do
        {:ok, _email} = Accounts.deliver_step_up_instructions(user, device, &"link:#{&1}")
      end

      assert {:error, :rate_limited} =
               Accounts.deliver_step_up_instructions(user, device, &"link:#{&1}")
    end
  end

  defp device_row(user) do
    bearer = Accounts.create_device_token(user, "test device")
    Accounts.get_device_token(bearer)
  end

  defp token_ids(user) do
    Repo.all(
      from t in UserToken,
        where: t.user_id == ^user.id and t.context != "step-up",
        select: t.id,
        order_by: t.id
    )
  end
end
