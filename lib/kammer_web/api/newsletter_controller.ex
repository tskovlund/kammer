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

  @spec subscribe(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def subscribe(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with %Community{} = community <- Communities.get_community_by_slug(slug) || :gone,
         {:ok, group} <- Groups.fetch_viewable_group(nil, community, group_slug),
         :ok <-
           Newsletters.request_subscription(
             group,
             Map.take(params, ~w(email display_name cadence)),
             client_ip: conn.remote_ip,
             confirm_url_fun: &PublicLinks.confirm_url(conn, :newsletter, &1)
           ) do
      conn |> put_status(202) |> json(%{status: "confirmation_sent"})
    else
      :gone -> ApiError.send(conn, :not_found, "Not found.")
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
