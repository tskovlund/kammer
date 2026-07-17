defmodule KammerWeb.ApiHelpers do
  @moduledoc """
  Shared helpers for JSON API tests: a conn carrying a fresh device
  token for the given user (ADR 0014), so each API test file doesn't
  grow its own copy — optionally pre-stepped-up for the
  credential-change endpoints behind the #294 gate.
  """

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Plug.Conn

  alias Kammer.Accounts
  alias Kammer.Accounts.UserToken
  alias Kammer.Repo

  @doc """
  A conn authenticated as `user` via a freshly minted device token.
  With `stepped_up: true` the token row is marked freshly stepped up
  (issue #294), so the conn passes the credential-change gate.
  """
  @spec api_conn(Kammer.Accounts.User.t(), stepped_up: boolean()) :: Plug.Conn.t()
  def api_conn(user, opts \\ []) do
    {token, user_token} = UserToken.build_device_token(user, "test device")
    inserted = Repo.insert!(user_token)
    if Keyword.get(opts, :stepped_up, false), do: Accounts.step_up_device(inserted)
    bearer_conn(token)
  end

  @doc """
  A JSON conn carrying `Authorization: Bearer <token>` for a literal
  token value — the guest management surface (ADR 0026), where the
  bearer is a signed guest token rather than a device token.
  """
  @spec bearer_conn(String.t()) :: Plug.Conn.t()
  def bearer_conn(token) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end
end
