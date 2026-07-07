defmodule Kammer.Assignments do
  @moduledoc """
  Assignments (issue #17, owner-designed): a flat task list per group —
  open / claimed / done, no columns, no sprints. "Unclaimed" is a
  first-class state: anyone in the group volunteers with one tap, and
  several people can hold the same assignment at once. Discussion uses
  the one comment engine (ADR 0007, third subject).

  Feature-gated per group (`:assignments`, OFF by default). Permissions
  delegate to `Kammer.Authorization`: creating follows the posting
  policy, claiming and completing follow the RSVP rule, editing and
  deleting is creator-or-moderator.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Assignments.Assignment
  alias Kammer.Assignments.AssignmentClaim
  alias Kammer.Authorization
  alias Kammer.Feed.Comment
  alias Kammer.Groups.Group
  alias Kammer.RateLimit
  alias Kammer.Repo

  @doc """
  Creates an assignment in a group.
  """
  @spec create_assignment(User.t(), Group.t(), map()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :not_found}
  def create_assignment(%User{} = creator, %Group{} = group, attrs) do
    with :ok <- Authorization.feature_gate(group, :assignments),
         :ok <- Authorization.authorize(creator, :post_in_group, group) do
      %Assignment{
        community_id: group.community_id,
        group_id: group.id,
        created_by_user_id: creator.id
      }
      |> Assignment.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  The group's assignment list: open ones first (due date, then age),
  done ones after.
  """
  @spec list_assignments(Group.t()) :: [Assignment.t()]
  def list_assignments(%Group{} = group) do
    Repo.all(
      from(assignment in Assignment,
        where: assignment.group_id == ^group.id,
        order_by: [
          asc: fragment("(? IS NOT NULL)", assignment.completed_at),
          asc_nulls_last: assignment.due_at,
          asc: assignment.inserted_at
        ],
        preload: [claims: :user]
      )
    )
  end

  @doc """
  Fetches an assignment the actor may see (view on the host group +
  feature gate), with claims and the discussion thread preloaded.
  """
  @spec fetch_viewable_assignment(User.t() | nil, Ecto.UUID.t()) ::
          {:ok, Assignment.t(), Group.t()} | {:error, :not_found | :unauthorized}
  def fetch_viewable_assignment(actor, assignment_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(assignment_id),
         %Assignment{} = assignment <- Repo.get(Assignment, assignment_id),
         %Group{} = group <- Repo.get(Group, assignment.group_id),
         :ok <- Authorization.feature_gate(group, :assignments),
         :ok <- Authorization.authorize(actor, :view_group, group) do
      {:ok, get_assignment!(assignment.id), group}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      _missing_or_invalid -> {:error, :not_found}
    end
  end

  @doc """
  Updates an assignment (creator or moderators).
  """
  @spec update_assignment(User.t(), Assignment.t(), map()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_assignment(%User{} = actor, %Assignment{} = assignment, attrs) do
    group = Repo.get!(Group, assignment.group_id)

    if can_manage_assignment?(actor, assignment, group) do
      assignment
      |> Assignment.changeset(attrs)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Deletes an assignment and its claims and discussion (creator or
  moderators).
  """
  @spec delete_assignment(User.t(), Assignment.t()) ::
          {:ok, Assignment.t()} | {:error, :unauthorized}
  def delete_assignment(%User{} = actor, %Assignment{} = assignment) do
    group = Repo.get!(Group, assignment.group_id)

    if can_manage_assignment?(actor, assignment, group) do
      Repo.delete(assignment)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Whether the actor may edit or delete the assignment — its creator or
  a group moderator.
  """
  @spec can_manage_assignment?(User.t() | nil, Assignment.t(), Group.t()) :: boolean()
  def can_manage_assignment?(actor, %Assignment{} = assignment, %Group{} = group) do
    Authorization.can_manage_own_resource?(actor, assignment.created_by_user_id, group)
  end

  @doc """
  Claims an assignment: "I'll take it". Several people may.
  """
  @spec claim(User.t(), Assignment.t()) ::
          {:ok, AssignmentClaim.t()} | {:error, :unauthorized | :done | Ecto.Changeset.t()}
  def claim(%User{} = actor, %Assignment{} = assignment) do
    group = Repo.get!(Group, assignment.group_id)
    relationship = Authorization.relationship(actor, group)

    cond do
      Assignment.done?(assignment) ->
        {:error, :done}

      not Authorization.can_react?(actor, group, relationship) ->
        {:error, :unauthorized}

      true ->
        %AssignmentClaim{}
        |> AssignmentClaim.changeset(%{assignment_id: assignment.id, user_id: actor.id})
        |> Repo.insert()
    end
  end

  @doc """
  Releases a claim: your own, or any if you manage the assignment.
  """
  @spec unclaim(User.t(), AssignmentClaim.t()) ::
          {:ok, AssignmentClaim.t()} | {:error, :unauthorized}
  def unclaim(%User{} = actor, %AssignmentClaim{} = claim) do
    assignment = Repo.get!(Assignment, claim.assignment_id)
    group = Repo.get!(Group, assignment.group_id)

    if claim.user_id == actor.id or can_manage_assignment?(actor, assignment, group) do
      Repo.delete(claim)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Marks the assignment done (any group member — trust by default; the
  record shows who).
  """
  @spec complete(User.t(), Assignment.t()) ::
          {:ok, Assignment.t()} | {:error, :unauthorized | :done}
  def complete(%User{} = actor, %Assignment{} = assignment) do
    group = Repo.get!(Group, assignment.group_id)
    relationship = Authorization.relationship(actor, group)

    cond do
      Assignment.done?(assignment) ->
        {:error, :done}

      not Authorization.can_react?(actor, group, relationship) ->
        {:error, :unauthorized}

      true ->
        assignment
        |> Ecto.Changeset.change(
          completed_at: DateTime.utc_now(:second),
          completed_by_user_id: actor.id
        )
        |> Repo.update()
    end
  end

  @doc """
  Reopens a done assignment (same rule as completing).
  """
  @spec reopen(User.t(), Assignment.t()) ::
          {:ok, Assignment.t()} | {:error, :unauthorized}
  def reopen(%User{} = actor, %Assignment{completed_at: %DateTime{}} = assignment) do
    group = Repo.get!(Group, assignment.group_id)
    relationship = Authorization.relationship(actor, group)

    if Authorization.can_react?(actor, group, relationship) do
      assignment
      |> Ecto.Changeset.change(completed_at: nil, completed_by_user_id: nil)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  def reopen(%User{}, %Assignment{}), do: {:error, :unauthorized}

  @doc """
  Comments on an assignment — the one engine, third subject (ADR 0007).
  Follows the group's comment policy like posts and events do.
  """
  @spec create_comment(User.t(), Assignment.t(), map()) ::
          {:ok, Comment.t()} | {:error, Ecto.Changeset.t() | :unauthorized | :rate_limited}
  def create_comment(%User{} = author, %Assignment{} = assignment, attrs) do
    group = Repo.get!(Group, assignment.group_id)

    cond do
      not Authorization.can?(author, :comment_in_group, group) ->
        {:error, :unauthorized}

      match?({:deny, _retry}, RateLimit.hit_comment_create(author.id)) ->
        {:error, :rate_limited}

      true ->
        parent_id = normalize_parent(attrs["parent_comment_id"])

        %Comment{assignment_id: assignment.id, author_user_id: author.id}
        |> Comment.create_changeset(%{
          "body_markdown" => attrs["body_markdown"],
          "parent_comment_id" => parent_id
        })
        |> Repo.insert()
    end
  end

  defp normalize_parent(nil), do: nil
  defp normalize_parent(""), do: nil

  defp normalize_parent(parent_comment_id) do
    case Repo.get(Comment, parent_comment_id) do
      nil -> nil
      %Comment{parent_comment_id: nil} = parent -> parent.id
      %Comment{parent_comment_id: grandparent_id} -> grandparent_id
    end
  end

  defp get_assignment!(assignment_id) do
    Repo.one!(
      from(assignment in Assignment,
        where: assignment.id == ^assignment_id,
        preload: [
          :created_by_user,
          :completed_by_user,
          claims: :user,
          comments: [:author_user, replies: [:author_user]]
        ]
      )
    )
  end
end
