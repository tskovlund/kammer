defmodule KammerWeb.NewsletterController do
  @moduledoc """
  Newsletter unsubscribe endpoints (SPEC §8): the plain GET a human
  might click, and the RFC 8058 one-click POST a mail client fires with
  no session at all. Both take a *scoped* token (issue #233): it names
  its own subscription, so the id is never a separate, attacker-variable
  request value, and it authorizes nothing beyond that one subscription
  — never the guest's full-power management token, since a mail gateway
  auto-fetches this URL with no human in the loop.

  Confirming a subscription happens over the JSON API now
  (`POST /api/v1/newsletter/confirm`), landing the emailed link in the
  PWA (ADR 0024, issue #187) — only the unsubscribe links, which have no
  PWA route, stay server-rendered here. Both actions answer 200
  regardless of whether the token was valid, so neither leaks it.
  """

  use KammerWeb, :controller

  alias Kammer.Newsletters

  @spec unsubscribe(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unsubscribe(conn, %{"token" => token}) do
    Newsletters.unsubscribe_by_scoped_token(token)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, gettext("You're unsubscribed."))
  end

  @spec unsubscribe_one_click(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unsubscribe_one_click(conn, %{"token" => token}) do
    Newsletters.unsubscribe_by_scoped_token(token)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "Unsubscribed.")
  end
end
