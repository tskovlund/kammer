defmodule KammerWeb.Api.CommunityController do
  @moduledoc """
  Communities and their groups over the API (RFC 0001). Listing is the
  member's own communities; group listings run through the same
  `listable_groups_query` the UI uses — sealed and private groups are
  exactly as invisible here as there.
  """

  use KammerWeb, :controller

  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Groups
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    user = conn.assigns.current_scope.user
    communities = Communities.list_user_communities(user)

    json(conn, %{
      data:
        Enum.map(communities, fn community ->
          Serializer.community(community, user, Authorization.relationship(user, community))
        end)
    })
  end

  @spec groups(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def groups(conn, %{"community_slug" => slug}) do
    user = conn.assigns.current_scope.user

    case Communities.get_community_by_slug(slug) do
      nil ->
        ApiError.send(conn, :not_found, "Not found.")

      community ->
        active = Groups.list_active_groups(user, community)
        archived = Groups.list_archived_groups(user, community)

        json(conn, %{
          data:
            Enum.map(active ++ archived, fn group ->
              Serializer.group(group, user, Authorization.relationship(user, group))
            end)
        })
    end
  end
end
