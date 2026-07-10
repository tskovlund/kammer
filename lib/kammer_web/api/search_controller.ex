defmodule KammerWeb.Api.SearchController do
  @moduledoc """
  Global search over the API (RFC 0001, issue #184, SPEC §16): one
  community-scoped endpoint returning matching posts, comments, events,
  and files. The narrowing is entirely `Kammer.Search`'s — it applies
  the same listing-visibility and folder-permission invariants the
  contexts enforce, so a result never surfaces what the viewer couldn't
  already see. The controller adds transport, never policy.
  """

  use KammerWeb, :controller

  alias Kammer.Communities
  alias Kammer.Search
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @spec search(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search(conn, %{"community_slug" => slug} = params) do
    case Communities.get_community_by_slug(slug) do
      nil ->
        ApiError.send(conn, :not_found, "Not found.")

      community ->
        user = conn.assigns.current_scope.user
        results = Search.search(user, community, params["q"] || "")
        json(conn, %{data: Serializer.search_results(results, user)})
    end
  end
end
