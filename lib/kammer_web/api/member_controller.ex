defmodule KammerWeb.Api.MemberController do
  @moduledoc """
  The community member directory and membership lifecycle over the API
  (SPEC §4, issue #182): the roster with per-viewer field redaction and
  custom-field filters (ADR 0020), admin role changes and removals, and
  leaving — all through the same context functions and authorization
  the members LiveView uses; the controller adds transport, never
  policy.

  Redaction follows ADR 0020: which contact and custom fields render is
  a local predicate in the contexts (`visible_contact_fields`,
  `list_visible_custom_fields`), fed the viewer's role from
  `Authorization.relationship/2`; the central module only answers
  whether the caller may see the roster at all. No-oracle: memberships
  are visible exactly to those who may view the directory, so
  member-addressed writes from anyone else answer 404 for every user
  id; a directory viewer without admin rights gets an honest 403 on
  writes — the roster already told them the member exists.
  """

  use KammerWeb, :controller

  alias Kammer.Accounts
  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Communities.Community
  alias Kammer.Communities.CommunityMembership
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @roles ~w(owner admin member)

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"community_slug" => slug} = params) do
    with_community(conn, slug, fn community, user ->
      with {:ok, memberships} <- Communities.list_members(user, community) do
        viewer_role = Authorization.relationship(user, community).community_role
        visible_fields = Communities.list_visible_custom_fields(community, viewer_role)

        values_by_user =
          Communities.custom_field_values_by_user(community, Enum.map(memberships, & &1.user))

        filters = directory_filters(params, visible_fields)

        data =
          memberships
          |> Enum.filter(&matches_filters?(&1, values_by_user, filters))
          |> Enum.map(fn membership ->
            Serializer.member(
              membership,
              Accounts.visible_contact_fields(membership.user, viewer_role),
              visible_values(values_by_user, membership.user_id, visible_fields)
            )
          end)

        json(conn, %{data: data, fields: Enum.map(visible_fields, &Serializer.custom_field/1)})
      end
    end)
  end

  @spec update_role(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_role(conn, %{"community_slug" => slug, "user_id" => user_id, "role" => role})
      when role in @roles do
    with_membership(conn, slug, user_id, fn community, membership, user ->
      with {:ok, updated} <-
             Communities.update_member_role(
               user,
               community,
               membership,
               String.to_existing_atom(role)
             ) do
        json(conn, %{data: %{user_id: updated.user_id, role: updated.role}})
      end
    end)
  end

  def update_role(conn, _params),
    do: ApiError.send(conn, :bad_request, "role must be one of owner, admin, member.")

  @spec remove(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def remove(conn, %{"community_slug" => slug, "user_id" => user_id}) do
    with_membership(conn, slug, user_id, fn community, membership, user ->
      with {:ok, _removed} <- Communities.remove_member(user, community, membership) do
        json(conn, %{status: "removed"})
      end
    end)
  end

  @spec leave(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def leave(conn, %{"community_slug" => slug}) do
    with_community(conn, slug, fn community, user ->
      case Communities.get_membership(community, user) do
        nil ->
          {:error, :not_found}

        membership ->
          with {:ok, _removed} <- Communities.remove_member(user, community, membership) do
            json(conn, %{status: "left"})
          end
      end
    end)
  end

  ## Internals

  # Only filters on fields the viewer may see apply — a filter on a
  # hidden field must never act as an oracle for its values, so it is
  # ignored rather than honored.
  defp directory_filters(%{"filter" => %{} = filter}, visible_fields) do
    visible_ids = MapSet.new(visible_fields, & &1.id)

    filter
    |> Enum.filter(fn {field_id, value} ->
      MapSet.member?(visible_ids, field_id) and is_binary(value) and value != ""
    end)
    |> Map.new()
  end

  defp directory_filters(_params, _visible_fields), do: %{}

  defp matches_filters?(_membership, _values_by_user, filters) when map_size(filters) == 0,
    do: true

  defp matches_filters?(membership, values_by_user, filters) do
    member_values = Map.get(values_by_user, membership.user_id, %{})
    Enum.all?(filters, fn {field_id, value} -> Map.get(member_values, field_id) == value end)
  end

  defp visible_values(values_by_user, user_id, visible_fields) do
    member_values = Map.get(values_by_user, user_id, %{})

    Map.new(
      for field <- visible_fields,
          {:ok, value} <- [Map.fetch(member_values, field.id)],
          do: {field.id, value}
    )
  end

  # The shared head of member-addressed writes: someone who may not
  # view the directory can see no membership, so every user id answers
  # 404 for them; a missing membership answers the same.
  defp with_membership(conn, slug, user_id, fun) do
    with_community(conn, slug, fn community, user ->
      with :ok <- directory_gate(user, community),
           %CommunityMembership{} = membership <-
             Communities.get_membership_by_user_id(community, user_id) || {:error, :not_found} do
        fun.(community, membership, user)
      end
    end)
  end

  defp directory_gate(user, community) do
    case Authorization.authorize(user, :view_member_directory, community) do
      :ok -> :ok
      {:error, :unauthorized} -> {:error, :not_found}
    end
  end

  defp with_community(conn, slug, fun) do
    user = conn.assigns.current_scope.user

    with %Community{} = community <- Communities.get_community_by_slug(slug),
         %Plug.Conn{} = responded <- fun.(community, user) do
      responded
    else
      nil -> ApiError.send(conn, :not_found, "Not found.")
      error -> ApiError.from_result(conn, error)
    end
  end
end
