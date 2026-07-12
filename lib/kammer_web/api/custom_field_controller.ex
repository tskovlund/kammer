defmodule KammerWeb.Api.CustomFieldController do
  @moduledoc """
  Community-defined profile-field *definitions* over the API (issue
  #259, part of #187, ADR 0020) — the manager surface the LiveView
  community-settings page owned: list the fields, add one, edit its
  label / visibility / required flag, delete one. The *answers* live on
  `ProfileController`; this is the schema of the roster's columns.

  Every action requires `:manage_community` (enforced in the context
  for the writes, in `with_manageable_community/3` for the list).
  Definitions aren't a secret — members already see them on the profile
  form — so a denied caller gets an honest 403 on `index`/`create`
  (the instance-ban precedent, not the no-oracle moderation queue).
  `update`/`delete` resolve the field first, so a missing or
  cross-community id is a 404 before the authorization check runs;
  `Communities.get_custom_field/2` does the community scoping.
  """

  use KammerWeb, :controller

  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Communities.CustomField
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  # Creation sets the whole definition. A field's `field_type` and its
  # `options` are frozen once it exists — changing them after members
  # answer would orphan those values — but its `label`, `visibility`,
  # and `required` flag stay editable. (The LiveView only toggled
  # required; the PWA does better than that first iteration.)
  @create_fields ~w(label field_type options visibility required)
  @update_fields ~w(label visibility required)

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"community_slug" => slug}) do
    with_manageable_community(conn, slug, fn community ->
      json(conn, %{
        data:
          community |> Communities.list_custom_fields() |> Enum.map(&Serializer.custom_field/1)
      })
    end)
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"community_slug" => slug} = params) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      case Communities.create_custom_field(user, community, Map.take(params, @create_fields)) do
        {:ok, field} ->
          conn
          |> put_status(:created)
          |> json(%{data: Serializer.custom_field(field)})

        error ->
          ApiError.from_result(conn, error)
      end
    end)
  end

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"community_slug" => slug, "id" => id} = params) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      with %CustomField{} = field <- Communities.get_custom_field(community, id),
           {:ok, updated} <-
             Communities.update_custom_field(
               user,
               community,
               field,
               Map.take(params, @update_fields)
             ) do
        json(conn, %{data: Serializer.custom_field(updated)})
      else
        nil -> ApiError.send(conn, :not_found, "Not found.")
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"community_slug" => slug, "id" => id}) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      with %CustomField{} = field <- Communities.get_custom_field(community, id),
           {:ok, _deleted} <- Communities.delete_custom_field(user, community, field) do
        json(conn, %{status: "deleted"})
      else
        nil -> ApiError.send(conn, :not_found, "Not found.")
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  # The list is manager-only, but its contents aren't secret — members
  # see the fields on the profile form — so a denied caller gets an
  # honest 403, mirroring the instance-ban list rather than the
  # no-oracle moderation queue. The writes below authorize in the
  # context (`create/update/delete_custom_field`), so they need only the
  # plain community lookup.
  defp with_manageable_community(conn, slug, fun) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      if Authorization.can?(user, :manage_community, community) do
        fun.(community)
      else
        ApiError.send(conn, :forbidden, "You are not allowed to do that.")
      end
    end)
  end

  defp with_community(conn, slug, fun) do
    case Communities.get_community_by_slug(slug) do
      nil -> ApiError.send(conn, :not_found, "Not found.")
      community -> fun.(community)
    end
  end
end
