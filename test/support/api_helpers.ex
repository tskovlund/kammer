defmodule KammerWeb.ApiHelpers do
  @moduledoc """
  Shared helpers for JSON API tests: a conn carrying a fresh device
  token for the given user (ADR 0014), so each API test file doesn't
  grow its own copy.
  """

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Plug.Conn

  alias Kammer.Accounts.UserToken
  alias Kammer.Repo

  @spec api_conn(Kammer.Accounts.User.t()) :: Plug.Conn.t()
  def api_conn(user) do
    {token, user_token} = UserToken.build_device_token(user, "test device")
    Repo.insert!(user_token)

    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end
end
