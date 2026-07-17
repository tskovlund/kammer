defmodule KammerWeb.NewsletterController do
  @moduledoc """
  Newsletter unsubscribe endpoints (SPEC §8): the plain GET a human
  follows from the `List-Unsubscribe` header, and the RFC 8058
  one-click POST a mail client fires with no session at all. Both take
  a *scoped* token (issue #233): it names its own subscription, so the
  id is never a separate, attacker-variable request value, and it
  authorizes nothing beyond that one subscription — never the guest's
  full-power management token, since a mail gateway auto-fetches this
  URL with no human in the loop.

  The GET deletes nothing (issue #239): GET is a safe method (RFC 7231
  §4.2.1), and non-RFC-8058 mail scanners and corporate link-checkers
  GET every URL in an email with no human involved — an inline delete
  would let them silently unsubscribe the guest. So the GET renders a
  self-contained confirmation page whose one button fires the POST,
  and only the POST deletes. Neither response depends on token
  validity: valid, expired, and garbage tokens all get the same 200
  page, so neither leaks whether a token named a live subscription.

  Confirming a subscription happens over the JSON API
  (`POST /api/v1/newsletter/confirm`), landing the emailed link in the
  PWA (ADR 0024, issue #187) — only the unsubscribe links, which have
  no PWA route, stay server-rendered here. Guests have no locale
  preference, so both pages use the instance default locale, same as
  the guest emails.
  """

  use KammerWeb, :controller

  alias Kammer.Newsletters

  @spec unsubscribe(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unsubscribe(conn, %{"token" => token}) do
    KammerWeb.Gettext.with_instance_locale(fn ->
      send_page(
        conn,
        page(gettext("Unsubscribe from this newsletter?"), """
        <p>#{escape(gettext("You'll stop receiving these emails."))}</p>
        <form method="post" action="#{escape(~p"/newsletter/unsubscribe/#{token}")}">
          <button type="submit">#{escape(gettext("Confirm unsubscribe"))}</button>
        </form>
        """)
      )
    end)
  end

  @spec unsubscribe_one_click(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unsubscribe_one_click(conn, %{"token" => token}) do
    Newsletters.unsubscribe_by_scoped_token(token)

    KammerWeb.Gettext.with_instance_locale(fn ->
      send_page(
        conn,
        page(
          gettext("You're unsubscribed."),
          "<p>#{escape(gettext("You won't receive these emails anymore."))}</p>"
        )
      )
    end)
  end

  # Sobelow can't see that every interpolated value in `page/2` passes
  # `escape/1` — the only request-derived one is the token, which is
  # additionally URL-encoded by `~p` before escaping. The CSP confines
  # any future slip regardless: no scripts, no remote loads, and the
  # form can only target this origin.
  # sobelow_skip ["XSS.SendResp"]
  defp send_page(conn, body) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; " <>
        "base-uri 'none'; frame-ancestors 'none'"
    )
    # The page is fetched at a token-bearing URL — never let a shared
    # cache store it. x-frame-options is the pre-CSP twin of
    # frame-ancestors for older engines.
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-frame-options", "DENY")
    |> send_resp(200, body)
  end

  # A self-contained page — the only HTML this server renders itself
  # since the LiveView cut (#187), so no layout or asset pipeline
  # stands behind it. The inline styles echo the PWA's paper/ink/accent
  # palette (SPEC §21, clients/web/src/routes/layout.css) in both
  # themes. Every interpolated value is HTML-escaped — `heading` and
  # the `lang` locale here, the token and copy in the callers above;
  # only `inner_html` is markup, by contract.
  defp page(heading, inner_html) do
    """
    <!DOCTYPE html>
    <html lang="#{escape(Gettext.get_locale(KammerWeb.Gettext))}">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{escape(heading)}</title>
        <style>
          body { margin: 0; min-height: 100vh; display: grid; place-items: center;
                 font-family: system-ui, sans-serif;
                 background: #f6f4f0; color: #211d18; }
          main { max-width: 26rem; padding: 2rem; text-align: center; }
          h1 { font-size: 1.25rem; }
          p { color: #5c564d; }
          button { font: inherit; padding: 0.6rem 1.4rem; border: none;
                   border-radius: 0.5rem; cursor: pointer;
                   background: #8a4b24; color: #fcfbf8; }
          @media (prefers-color-scheme: dark) {
            body { background: #181512; color: #ece7df; }
            p { color: #a69e92; }
            button { background: #d99a66; color: #241505; }
          }
        </style>
      </head>
      <body>
        <main>
          <h1>#{escape(heading)}</h1>
          #{inner_html}
        </main>
      </body>
    </html>
    """
  end

  defp escape(text), do: Plug.HTML.html_escape(text)
end
