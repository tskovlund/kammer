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

  # The community settings an admin may edit (issue #183): slug and
  # branding plus the two policy toggles. Storage/retention columns are
  # managed elsewhere and never cast here.
  @update_fields ~w(name slug description accent_color default_locale listed_on_instance require_real_names)

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
        groups =
          Groups.list_active_groups(user, community) ++
            Groups.list_archived_groups(user, community)

        # Batched: two lookups for the whole list, not two per group.
        relationships = Authorization.group_relationships(user, community, groups)

        json(conn, %{
          data:
            Enum.map(groups, fn group ->
              Serializer.group(group, user, relationships[group.id])
            end)
        })
    end
  end

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"community_slug" => slug} = params) do
    user = conn.assigns.current_scope.user

    case Communities.get_community_by_slug(slug) do
      nil ->
        ApiError.send(conn, :not_found, "Not found.")

      community ->
        case Communities.update_community(user, community, Map.take(params, @update_fields)) do
          {:ok, updated} ->
            json(conn, %{
              data: Serializer.community(updated, user, Authorization.relationship(user, updated))
            })

          error ->
            ApiError.from_result(conn, error)
        end
    end
  end
end
