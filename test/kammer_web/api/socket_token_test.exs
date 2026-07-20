defmodule KammerWeb.Api.SocketTokenTest do
  @moduledoc """
  The short-lived socket connect token (issue #175): a signed round-trip
  carries the user and device ids, an old token is refused, and only a
  well-formed `{user_id, device_id}` payload is accepted.
  """

  use ExUnit.Case, async: true

  alias KammerWeb.Api.SocketToken

  test "signs and verifies a round-trip, returning the bound user and device ids" do
    user_id = Ecto.UUID.generate()
    device_id = Ecto.UUID.generate()

    assert {:ok, ^user_id, ^device_id} = SocketToken.verify(SocketToken.sign(user_id, device_id))
  end

  test "refuses a token older than the max age" do
    user_id = Ecto.UUID.generate()
    device_id = Ecto.UUID.generate()

    # Signed with the module's own salt but a stale timestamp. Asserting
    # `:expired` specifically (not merely `:error`) means a salt drift — which
    # would surface as `:invalid` — fails this test rather than passing it, so
    # it genuinely pins the max-age wiring.
    stale =
      Phoenix.Token.sign(
        KammerWeb.Endpoint,
        "api socket token",
        {user_id, device_id},
        signed_at: System.system_time(:second) - SocketToken.max_age_seconds() - 5
      )

    assert {:error, :expired} = SocketToken.verify(stale)
  end

  test "refuses garbage, a non-binary, and a validly-signed but wrong-shape payload" do
    assert {:error, _reason} = SocketToken.verify("garbage")
    assert {:error, :invalid} = SocketToken.verify(nil)

    wrong_shape = Phoenix.Token.sign(KammerWeb.Endpoint, "api socket token", "not-a-tuple")
    assert {:error, :invalid} = SocketToken.verify(wrong_shape)
  end
end
