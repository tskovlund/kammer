defmodule KammerWeb.PwaController do
  @moduledoc """
  SPA fallback for the instance-served Svelte PWA (ADR 0024, issue #176).

  Real files under the PWA base path (hashed `_app/` assets, the web
  manifest, icons) are served by `Plug.Static` in the endpoint; every
  other request under the base path lands here and gets the client's
  `index.html`, so client-side routes — `/app/sign-in/{token}` from a
  magic-link email, most importantly — deep-link straight into the SPA.

  When no client bundle is present (plain `mix phx.server` without a
  release build — the bundle is produced by the Dockerfile's client
  stage), this answers with a plain-text pointer instead of a 500: in
  development the client runs as its own dev server (`pnpm dev` in
  `clients/web`, see docs/development.md).
  """

  use KammerWeb, :controller

  @not_bundled """
  The Kammer web client is not bundled in this build.

  Release images build and serve it automatically. In development, run
  it as its own dev server instead:

      cd clients/web && pnpm dev

  See docs/development.md for details.
  """

  # The SPA's own CSP. SvelteKit's static output boots from inline
  # scripts baked into index.html at build time, so the nonce-based
  # policy the browser pipeline uses (CspNonce) cannot apply to a
  # prebuilt file — hence 'unsafe-inline' for scripts, as a functional
  # baseline. Tightening it (build-time script hashes via SvelteKit's
  # `kit.csp`) is tracked in issue #163. connect-src allows any https/wss
  # origin on purpose: the client merges multiple Kammer instances
  # (ADR 0023), whose domains this server cannot know.
  @csp "default-src 'self'; script-src 'self' 'unsafe-inline'; " <>
         "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; " <>
         "connect-src 'self' https: wss:; object-src 'none'; " <>
         "frame-ancestors 'self'; base-uri 'self'"

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    index = Path.join(client_root(), "index.html")

    if File.regular?(index) do
      conn
      |> put_resp_header("content-security-policy", @csp)
      # The fallback document names the hashed asset files of exactly one
      # build — it must be revalidated on every navigation, or a stale
      # copy keeps pointing at assets a newer release no longer ships.
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_content_type("text/html")
      |> send_file(200, index)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, @not_bundled)
    end
  end

  # Runtime-read so tests can point it at a fixture; everywhere else it
  # is the release's priv/static/app (where the Dockerfile puts the
  # client build).
  defp client_root do
    Application.get_env(:kammer, :pwa_client_root) ||
      Application.app_dir(:kammer, "priv/static/app")
  end
end
