defmodule KammerWeb.Api.GroupController do
  @moduledoc """
  Group management over the API (RFC 0001, issue #183): create a group,
  edit its settings, toggle features (ADR 0016), and archive/unarchive
  (SPEC §3). All policy lives in `Kammer.Groups` / `Kammer.Authorization`
  — the controller only shapes transport and threads the viewer's
  relationship into the serializer so the response carries the fresh
  `viewer_can`.

  Programmatic fields (`community_id`, `sealed` after creation) are
  never cast from the request; the context/changeset owns them. A group
  the caller can't see answers 404 to every management verb, exactly
  like one that doesn't exist (#156/#161).
  """

  use KammerWeb, :controller

  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Groups
  alias Kammer.Groups.Group
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  # The settings a caller may set on create. `sealed` is create-only and
  # irreversible (ADR 0005); the update changeset never casts it.
  @create_fields ~w(name slug description visibility join_policy posting_policy comment_policy approval_queue sealed)
  @update_fields ~w(name slug description visibility join_policy posting_policy comment_policy approval_queue version_retention)

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"community_slug" => slug} = params) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      case Groups.create_group(user, community, Map.take(params, @create_fields)) do
        {:ok, group} -> render_group(conn, user, group, :created)
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_group(conn, slug, group_slug, fn user, group ->
      case Groups.update_group(user, group, Map.take(params, @update_fields)) do
        {:ok, updated} -> render_group(conn, user, updated)
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec features(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def features(conn, %{
        "community_slug" => slug,
        "group_slug" => group_slug,
        "features" => features
      })
      when is_list(features) do
    with_group(conn, slug, group_slug, fn user, group ->
      case Groups.update_group_features(user, group, features) do
        {:ok, updated} -> render_group(conn, user, updated)
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  def features(conn, _params),
    do: ApiError.send(conn, :bad_request, "features must be an array of feature names.")

  @spec archive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive(conn, %{"community_slug" => slug, "group_slug" => group_slug}) do
    with_group(conn, slug, group_slug, fn user, group ->
      case Groups.archive_group(user, group) do
        {:ok, updated} -> render_group(conn, user, updated)
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec unarchive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unarchive(conn, %{"community_slug" => slug, "group_slug" => group_slug}) do
    with_group(conn, slug, group_slug, fn user, group ->
      case Groups.unarchive_group(user, group) do
        {:ok, updated} -> render_group(conn, user, updated)
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  defp render_group(conn, user, %Group{} = group, status \\ :ok) do
    relationship = Authorization.relationship(user, group)

    conn
    |> put_status(status)
    |> json(%{data: Serializer.group(group, user, relationship)})
  end

  defp with_community(conn, slug, fun) do
    case Communities.get_community_by_slug(slug) do
      nil -> ApiError.send(conn, :not_found, "Not found.")
      community -> fun.(community)
    end
  end

  defp with_group(conn, community_slug, group_slug, fun) do
    user = conn.assigns.current_scope.user

    with %Communities.Community{} = community <-
           Communities.get_community_by_slug(community_slug),
         {:ok, group} <- Groups.fetch_viewable_group(user, community, group_slug) do
      fun.(user, group)
    else
      # No-oracle (#156/#161): a missing community, a missing group, and a
      # group the caller may not even *see* all answer the same 404 — an
      # unviewable group must be indistinguishable from a nonexistent one,
      # so `fetch_viewable_group`'s view-denied `{:error, :unauthorized}`
      # is folded into not-found here rather than surfacing as 403. (A
      # group the caller *can* see but not *manage* still gets an honest
      # 403 from the mutator inside `fun`.)
      nil -> ApiError.send(conn, :not_found, "Not found.")
      {:error, _reason} -> ApiError.send(conn, :not_found, "Not found.")
    end
  end
end
