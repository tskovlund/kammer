defmodule KammerWeb.Api.AuthController do
  @moduledoc """
  API sign-in (ADR 0014): the same passwordless flow as the web, over
  JSON. `register` creates an account (mirrors `UserLive.Registration`
  exactly — same changeset, same IP rate limit); `request_link` emails
  a magic link (neutral response — no account enumeration);
  `exchange` trades the single-use magic token for a long-lived
  device token; `revoke` signs the device out.
  """

  use KammerWeb, :controller

  alias Kammer.Accounts
  alias KammerWeb.ApiAuth
  alias KammerWeb.ApiError

  @spec register(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def register(conn, params) do
    attrs = Map.take(params, ["email", "display_name"])

    case Accounts.register_user(attrs, ip: conn.remote_ip) do
      {:ok, user} ->
        Accounts.deliver_login_instructions(
          user,
          fn token -> unverified_url(conn, "/users/log-in/#{token}") end,
          ip: conn.remote_ip
        )

        conn
        |> put_status(201)
        |> json(%{
          status: "confirmation_sent",
          user: %{id: user.id, email: user.email, display_name: user.display_name}
        })

      error ->
        ApiError.from_result(conn, error)
    end
  end

  @spec request_link(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request_link(conn, %{"email" => email}) when is_binary(email) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        fn token -> unverified_url(conn, "/users/log-in/#{token}") end,
        ip: conn.remote_ip
      )
    end

    # Deliberately identical for unknown addresses (SPEC §11).
    json(conn, %{status: "sent"})
  end

  def request_link(conn, _params),
    do: ApiError.send(conn, :bad_request, "An email address is required.")

  @spec exchange(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def exchange(conn, %{"magic_token" => magic_token} = params) when is_binary(magic_token) do
    device_name = params["device_name"]

    case Accounts.exchange_magic_link_for_device_token(magic_token, device_name) do
      {:ok, device_token, user} ->
        json(conn, %{
          device_token: device_token,
          user: %{id: user.id, email: user.email, display_name: user.display_name}
        })

      {:error, :not_found} ->
        ApiError.send(conn, :unauthorized, "That sign-in link is invalid or has expired.")
    end
  end

  def exchange(conn, _params),
    do: ApiError.send(conn, :bad_request, "A magic_token is required.")

  @spec revoke(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def revoke(conn, _params) do
    case ApiAuth.bearer_token(conn) do
      nil -> :ok
      token -> Accounts.revoke_device_token(token)
    end

    json(conn, %{status: "revoked"})
  end
end
