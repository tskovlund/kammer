defmodule KammerWeb.UserSessionController do
  @moduledoc """
  Completes magic-link sign-in (the only sign-in method, SPEC §2) and
  handles logout.
  """

  use KammerWeb, :controller

  alias Kammer.Accounts
  alias KammerWeb.UserAuth

  @doc """
  Logs the user in from a magic-link token. Links are single-use and
  short-lived; first use also confirms the account.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, gettext("Welcome! Your account is confirmed."))
  end

  def create(conn, params) do
    create(conn, params, gettext("Welcome back!"))
  end

  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _error ->
        conn
        |> put_flash(:error, gettext("The link is invalid or it has expired."))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  Finalizes a passkey sign-in (ADR 0018). The WebAuthn assertion was
  already verified inside the `UserLive.Login` process; this only
  exchanges the single-use hand-off token for a real session, since
  setting the session cookie needs a `conn` the LiveView doesn't have.
  """
  @spec create_from_passkey(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_from_passkey(conn, %{"user" => %{"token" => token} = user_params}) do
    case Accounts.login_user_by_passkey_exchange_token(token) do
      {:ok, user} ->
        conn
        |> put_flash(:info, gettext("Welcome back!"))
        |> UserAuth.log_in_user(user, user_params)

      {:error, :not_found} ->
        conn
        |> put_flash(:error, gettext("The passkey sign-in expired. Please try again."))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  @doc """
  Logs the user out of the current session.
  """
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("Logged out successfully."))
    |> UserAuth.log_out_user()
  end
end
