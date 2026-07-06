defmodule KammerWeb.ApiAuth do
  @moduledoc """
  Bearer authentication for the JSON API (ADR 0014): resolves an API
  device token to the same `current_scope` the browser stack uses, so
  controllers and contexts cannot tell transports apart — and neither
  can the authorization module, which is the point.
  """

  import Plug.Conn

  alias Kammer.Accounts
  alias Kammer.Accounts.Scope

  @doc "Assigns `current_scope` from a Bearer device token (or nil scope)."
  @spec fetch_api_scope(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_api_scope(conn, _opts) do
    user =
      case bearer_token(conn) do
        nil -> nil
        token -> Accounts.get_user_by_device_token(token)
      end

    assign(conn, :current_scope, Scope.for_user(user))
  end

  @doc "Halts with the standard 401 envelope when no user is present."
  @spec require_api_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_api_user(conn, _opts) do
    case conn.assigns.current_scope do
      %Scope{user: %Accounts.User{}} ->
        conn

      _anonymous ->
        conn
        |> KammerWeb.ApiError.send(:unauthorized, "A valid device token is required.")
        |> halt()
    end
  end

  @doc "The raw Bearer token of the current request, or nil."
  @spec bearer_token(Plug.Conn.t()) :: String.t() | nil
  def bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _rest] -> token
      _missing -> nil
    end
  end
end
