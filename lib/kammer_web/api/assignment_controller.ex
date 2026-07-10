defmodule KammerWeb.Api.AssignmentController do
  @moduledoc """
  Assignments over the API (RFC 0001, issue #184): the group's task
  list and full parity — create, edit, delete, claim/unclaim,
  complete/reopen, and the shared comment engine (ADR 0007). Every
  decision runs through `Kammer.Assignments` and `Kammer.Authorization`;
  the controller adds transport, never policy.

  Feature-gated per group (`:assignments`, ADR 0016): a group without
  the tool is unreachable. No-oracle (#156/#161): an assignment the
  caller may not see answers 404 to every verb; a visible one the caller
  may not edit/delete still 403s.
  """

  use KammerWeb, :controller

  alias Kammer.Assignments
  alias Kammer.Assignments.AssignmentClaim
  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Communities.Community
  alias Kammer.Groups
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @feature :assignments
  @fields ~w(title notes_markdown due_at)

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"community_slug" => slug, "group_slug" => group_slug}) do
    with_feature_group(conn, slug, group_slug, fn _community, group, user ->
      relationship = Authorization.relationship(user, group)
      assignments = Assignments.list_assignments(group)

      json(conn, %{
        data: Enum.map(assignments, &Serializer.assignment(&1, user, group, relationship))
      })
    end)
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_feature_group(conn, slug, group_slug, fn _community, group, user ->
      with {:ok, assignment} <-
             Assignments.create_assignment(user, group, Map.take(params, @fields)) do
        respond_with_assignment(conn, assignment.id, user, 201)
      end
    end)
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    with_assignment(conn, params, fn assignment, group, user ->
      json(conn, %{data: assignment_data(assignment, group, user)})
    end)
  end

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, params) do
    with_assignment(conn, params, fn assignment, _group, user ->
      with {:ok, _updated} <-
             Assignments.update_assignment(user, assignment, Map.take(params, @fields)) do
        respond_with_assignment(conn, assignment.id, user)
      end
    end)
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, params) do
    with_assignment(conn, params, fn assignment, group, user ->
      with {:ok, deleted} <- Assignments.delete_assignment(user, assignment) do
        json(conn, %{data: assignment_data(deleted, group, user)})
      end
    end)
  end

  @spec claim(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def claim(conn, params) do
    with_assignment(conn, params, fn assignment, _group, user ->
      with {:ok, _claim} <- Assignments.claim(user, assignment) do
        respond_with_assignment(conn, assignment.id, user)
      end
    end)
  end

  @spec unclaim(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unclaim(conn, params) do
    with_assignment(conn, params, fn assignment, _group, user ->
      # Releasing over the API is always your own claim; a manager who
      # wants someone else's off deletes the assignment. No claim to
      # release is a no-op the caller can't observe as anything but 404.
      case Assignments.get_claim(assignment.id, user.id) do
        %AssignmentClaim{} = claim ->
          with {:ok, _released} <- Assignments.unclaim(user, claim) do
            respond_with_assignment(conn, assignment.id, user)
          end

        nil ->
          {:error, :not_found}
      end
    end)
  end

  @spec complete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def complete(conn, params) do
    with_assignment(conn, params, fn assignment, _group, user ->
      with {:ok, _done} <- Assignments.complete(user, assignment) do
        respond_with_assignment(conn, assignment.id, user)
      end
    end)
  end

  @spec reopen(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reopen(conn, params) do
    with_assignment(conn, params, fn assignment, _group, user ->
      with {:ok, _reopened} <- Assignments.reopen(user, assignment) do
        respond_with_assignment(conn, assignment.id, user)
      end
    end)
  end

  @spec create_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_comment(conn, params) do
    with_assignment(conn, params, fn assignment, _group, user ->
      attrs = Map.take(params, ["body_markdown", "parent_comment_id"])

      with {:ok, comment} <- Assignments.create_comment(user, assignment, attrs) do
        conn
        |> put_status(201)
        |> json(%{data: Serializer.comment(comment, user)})
      end
    end)
  end

  ## Internals

  defp assignment_data(assignment, group, user) do
    Serializer.assignment(assignment, user, group, Authorization.relationship(user, group))
  end

  defp with_feature_group(conn, community_slug, group_slug, fun) do
    user = conn.assigns.current_scope.user

    with %Community{} = community <- Communities.get_community_by_slug(community_slug),
         {:ok, group} <- Groups.fetch_viewable_group(user, community, group_slug),
         :ok <- Authorization.feature_gate(group, @feature) do
      fun.(community, group, user)
    else
      nil -> ApiError.send(conn, :not_found, "Not found.")
      error -> ApiError.from_result(conn, error)
    end
  end

  defp with_assignment(conn, %{"community_slug" => slug, "assignment_id" => id}, fun) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      with {:ok, assignment, group} <- fetch_visible_assignment(user, id),
           true <- assignment.community_id == community.id,
           %Plug.Conn{} = responded <- fun.(assignment, group, user) do
        responded
      else
        false -> ApiError.send(conn, :not_found, "Not found.")
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  defp with_community(conn, slug, fun) do
    case Communities.get_community_by_slug(slug) do
      nil -> ApiError.send(conn, :not_found, "Not found.")
      community -> fun.(community)
    end
  end

  defp fetch_visible_assignment(user, id) do
    case Assignments.fetch_viewable_assignment(user, id) do
      {:error, :unauthorized} -> {:error, :not_found}
      other -> other
    end
  end

  defp respond_with_assignment(conn, id, user, status \\ 200) do
    case fetch_visible_assignment(user, id) do
      {:ok, assignment, group} ->
        conn
        |> put_status(status)
        |> json(%{data: assignment_data(assignment, group, user)})

      error ->
        ApiError.from_result(conn, error)
    end
  end
end
