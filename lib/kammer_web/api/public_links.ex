defmodule KammerWeb.Api.PublicLinks do
  @moduledoc """
  Absolute email links and client-relative redirect paths for the
  tokenless guest/newsletter/setup API flows (issue #185, ADR 0024).

  The account-less flows are two-step: a request endpoint emails a
  signed link, and the recipient follows it into the instance-served
  PWA (ADR 0024), which calls the matching confirm/manage endpoint. So
  the confirm and management links these emails carry point at PWA
  routes under `:pwa_base_path` — the same landing convention
  `AuthController` uses for API-initiated sign-in emails — not at the
  LiveView routes the web flows still use. The signed token in the URL
  stays the whole credential (ADR 0013); only the host route changes.
  """

  import Phoenix.VerifiedRoutes, only: [unverified_url: 2]

  alias Kammer.Communities.Community
  alias Kammer.Events.Event
  alias Kammer.Groups.Group

  @confirm_paths %{
    rsvp: "/guest/rsvp/confirm/",
    comment: "/guest/comment/confirm/",
    claim: "/guest/claim/confirm/",
    newsletter: "/newsletter/confirm/"
  }

  @doc """
  Absolute PWA confirm link for a request email — the signed token in
  the path is the credential the confirm endpoint verifies.

  Unlike `manage_url/2`, this token stays in the path (ADR 0026): it's
  single-use — the confirm endpoint consumes it once — so it never
  accumulates in server logs the way a long-lived credential would; a
  captured link is a magic-link-equivalent bearer secret already, the
  same accepted trade-off as every other one-shot email link here.
  """
  @spec confirm_url(Plug.Conn.t(), :rsvp | :comment | :claim | :newsletter, String.t()) ::
          String.t()
  def confirm_url(conn, kind, token) do
    pwa_url(conn, Map.fetch!(@confirm_paths, kind) <> token)
  end

  @doc """
  Absolute PWA management link every confirmation email carries.

  The token rides the URL *fragment* (`#token`, not `/token`) rather
  than the path (issue #230, ADR 0026): the management token is
  long-lived, and a fragment is never sent to any server — not this
  one, not an intermediate proxy — so it can't leak into access logs,
  and browsers omit it from the `Referer` header on outbound
  navigation. The PWA reads it client-side and sends it back as
  `Authorization: Bearer <token>`.
  """
  @spec manage_url(Plug.Conn.t(), String.t()) :: String.t()
  def manage_url(conn, token), do: pwa_url(conn, "/guest/manage#" <> token)

  @doc "Absolute PWA sign-in link for the setup operator's first magic link."
  @spec sign_in_url(Plug.Conn.t(), String.t()) :: String.t()
  def sign_in_url(conn, token), do: pwa_url(conn, "/sign-in/" <> token)

  @doc """
  The client-relative path the PWA navigates to after a confirm — the
  API twin of the web confirm redirect, without the PWA base (the
  client router owns its own base).
  """
  @spec event_path(Event.t()) :: String.t()
  def event_path(%Event{community: %Community{} = community} = event),
    do: "/c/#{community.slug}/events/#{event.id}"

  @spec group_path(Group.t()) :: String.t()
  def group_path(%Group{community: %Community{} = community} = group),
    do: community_group_path(community, group)

  @doc """
  The group's client-relative path when the community is loaded
  alongside the group rather than on it (e.g. a post preloads both).
  """
  @spec community_group_path(Community.t(), Group.t()) :: String.t()
  def community_group_path(%Community{} = community, %Group{} = group),
    do: "/c/#{community.slug}/g/#{group.slug}"

  defp pwa_url(conn, path) do
    base = Application.get_env(:kammer, :pwa_base_path, "/app")
    unverified_url(conn, base <> path)
  end
end
