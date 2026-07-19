defmodule KammerWeb.UserAuth do
  @moduledoc """
  Session plug that resolves the current scope for browser requests
  (SPEC §2): reads the revocable session token and assigns
  `current_scope`.

  Account sign-in/out now happens over the JSON API with device tokens
  (ADR 0024, issue #187). There is no browser login flow left to
  establish a session, so this only *reads* one — enough for the
  surviving server-rendered surfaces (a single-event ICS download
  authorizes like its page when the request already carries a session)
  and it degrades to the anonymous scope otherwise. The remember-me and
  token-reissue machinery went with the login flow that wrote them.
  """

  import Plug.Conn

  alias Kammer.Accounts
  alias Kammer.Accounts.Scope
  alias Kammer.Moderation

  @doc """
  Assigns `current_scope` from the session's user token, or the
  anonymous scope when there is no valid session.
  """
  @spec fetch_current_scope_for_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_scope_for_user(conn, _opts) do
    user =
      with token when is_binary(token) <- get_session(conn, :user_token),
           {%Accounts.User{} = user, _token_inserted_at} <-
             Accounts.get_user_by_session_token(token) do
        user
      else
        _no_session -> nil
      end

    assign(conn, :current_scope, Scope.for_user(ban_gate(user)))
  end

  # Full instance-ban lockout (#377): the browser twin of
  # `KammerWeb.ApiAuth.ban_gate`, so the lockout holds by design at every
  # scope-establishment point — a banned account degrades to the anonymous
  # scope here too, not by the accident that no browser session is minted
  # today (sign-in is API-only, ADR 0024, so this path currently only ever
  # reads a carried-over session).
  defp ban_gate(nil), do: nil

  defp ban_gate(%Accounts.User{} = user) do
    if Moderation.instance_banned?(user.email), do: nil, else: user
  end
end
