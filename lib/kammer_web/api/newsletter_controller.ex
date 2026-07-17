defmodule KammerWeb.Api.NewsletterController do
  @moduledoc """
  Guest newsletter subscriptions over the API (issue #185, SPEC §8):
  the API twin of the web `NewsletterController` request/confirm
  landings. Public and tokenless — the signed confirm link is the whole
  credential (ADR 0013), same as every guest surface.

  Managing a subscription afterwards (changing cadence, unsubscribing)
  happens through the shared guest management token, so those live on
  `GuestController` alongside a guest's RSVPs and comments — the one
  management page the confirmation email links to. The RFC 8058
  one-click `List-Unsubscribe` POST stays a plain-HTTP endpoint (mail
  clients fire the exact URL from the header; it never speaks JSON), so
  it is deliberately not mirrored here.
  """

  use KammerWeb, :controller

  alias Kammer.Communities
  alias Kammer.Communities.Community
  alias Kammer.Groups
  alias Kammer.Newsletters
  alias KammerWeb.Api.PublicLinks
  alias KammerWeb.ApiError

  # No-oracle (#339, tightened in #345): this surface is anonymous, so
  # it resolves through the public fetch — a missing community, a
  # missing group, and a group that isn't publicly readable (private,
  # community-only, archived, or sealed) all fold into the same 404. A
  # 403 for a hidden-but-real group would hand a slug-guessing prober
  # a live existence oracle; the remaining 403 is only ever "this
  # group's page is public, but guest subscriptions are off."
  @spec subscribe(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def subscribe(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with %Community{} = community <-
           Communities.get_community_by_slug(slug) || {:error, :not_found},
         {:ok, group} <- Groups.fetch_public_group(community, group_slug),
         :ok <-
           Newsletters.request_subscription(
             group,
             Map.take(params, ~w(email display_name cadence)),
             client_ip: conn.remote_ip,
             confirm_url_fun: &PublicLinks.confirm_url(conn, :newsletter, &1)
           ) do
      conn |> put_status(202) |> json(%{status: "confirmation_sent"})
    else
      error -> ApiError.from_result(conn, error)
    end
  end

  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"token" => token}) when is_binary(token) do
    case Newsletters.confirm_subscription(token, &PublicLinks.manage_url(conn, &1)) do
      {:ok, group, _subscription} ->
        json(conn, %{data: %{guest_name: nil, redirect_path: PublicLinks.group_path(group)}})

      {:error, :invalid} ->
        ApiError.send(conn, :not_found, "This link is no longer valid.")
    end
  end

  def confirm(conn, _params),
    do: ApiError.send(conn, :bad_request, "A token is required.")
end
