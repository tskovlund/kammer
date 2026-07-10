defmodule Kammer.Groups do
  @moduledoc """
  Groups within communities (SPEC §3): creation with the four visibility
  presets and policies, membership lifecycle (open join, request/approval,
  invites are in `Kammer.Invitations`), roles, the irreversible sealed
  flag, and the archive state.

  All permission decisions are delegated to `Kammer.Authorization`.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Audit
  alias Kammer.Authorization
  alias Kammer.Communities.Community
  alias Kammer.Groups.Group
  alias Kammer.Groups.GroupJoinRequest
  alias Kammer.Groups.GroupMembership
  alias Kammer.Repo

  ## Reading

  @doc """
  Gets a group by community and slug with the community preloaded, raising
  if absent. Callers must still authorize `:view_group`.
  """
  @spec get_group_by_slug!(Community.t(), String.t()) :: Group.t()
  def get_group_by_slug!(%Community{} = community, slug) do
    group =
      Repo.one!(
        from(group in Group,
          where: group.community_id == ^community.id and group.slug == ^slug
        )
      )

    %Group{group | community: community}
  end

  @doc """
  Fetches a group the actor may view, or an error tuple.
  """
  @spec fetch_viewable_group(User.t() | nil, Community.t(), String.t()) ::
          {:ok, Group.t()} | {:error, :not_found | :unauthorized}
  def fetch_viewable_group(actor, %Community{} = community, slug) do
    case Repo.one(
           from(group in Group,
             where: group.community_id == ^community.id and group.slug == ^slug
           )
         ) do
      nil ->
        {:error, :not_found}

      %Group{} = group ->
        with :ok <- Authorization.authorize(actor, :view_group, group) do
          {:ok, %Group{group | community: community}}
        end
    end
  end

  @doc """
  Fetches a group the actor may view by id (with the community
  preloaded), or an error tuple. The id-addressed twin of
  `fetch_viewable_group/3` for callers that hold no slugs — realtime
  topics carry group ids. Invalid ids read as `{:error, :not_found}`.
  """
  @spec fetch_viewable_group_by_id(User.t() | nil, Ecto.UUID.t()) ::
          {:ok, Group.t()} | {:error, :not_found | :unauthorized}
  def fetch_viewable_group_by_id(actor, group_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(group_id),
         %Group{} = group <- Repo.one(from(group in Group, where: group.id == ^uuid)),
         :ok <- Authorization.authorize(actor, :view_group, group) do
      {:ok, Repo.preload(group, :community)}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      _missing -> {:error, :not_found}
    end
  end

  @doc """
  Active (non-archived) groups the actor should see in the community's
  group list. Visibility filtering lives in `Kammer.Authorization`.
  """
  @spec list_active_groups(User.t() | nil, Community.t()) :: [Group.t()]
  def list_active_groups(actor, %Community{} = community) do
    actor
    |> Authorization.listable_groups_query(community)
    |> where([group], is_nil(group.archived_at))
    |> order_by([group], group.name)
    |> Repo.all()
  end

  @doc """
  Archived groups the actor should see, for the "Archived" section
  (SPEC §3: hidden from active lists, browsable under Archived).
  """
  @spec list_archived_groups(User.t() | nil, Community.t()) :: [Group.t()]
  def list_archived_groups(actor, %Community{} = community) do
    actor
    |> Authorization.listable_groups_query(community)
    |> where([group], not is_nil(group.archived_at))
    |> order_by([group], group.name)
    |> Repo.all()
  end

  @doc """
  Groups the user is a member of in the community, for the sidebar.
  """
  @spec list_member_groups(User.t() | nil, Community.t()) :: [Group.t()]
  def list_member_groups(nil, %Community{}), do: []

  def list_member_groups(%User{} = user, %Community{} = community) do
    Repo.all(
      from(group in Group,
        join: membership in GroupMembership,
        on: membership.group_id == group.id,
        where:
          membership.user_id == ^user.id and group.community_id == ^community.id and
            is_nil(group.archived_at),
        order_by: group.name
      )
    )
  end

  @doc """
  The publicly listed groups of a community, for its public page
  (SPEC §3: `public_listed`).
  """
  @spec list_public_groups(Community.t()) :: [Group.t()]
  def list_public_groups(%Community{} = community) do
    Repo.all(
      from(group in Group,
        where:
          group.community_id == ^community.id and group.visibility == :public_listed and
            is_nil(group.archived_at),
        order_by: group.name
      )
    )
  end

  ## Writing

  @doc """
  Creates a group; the creator becomes its Owner. The sealed flag can only
  be set here (irreversible, ADR 0005). Requires `:create_group` on the
  community.
  """
  @spec create_group(User.t(), Community.t(), map()) ::
          {:ok, Group.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_group(%User{} = creator, %Community{} = community, attrs) do
    with :ok <- Authorization.authorize(creator, :create_group, community) do
      attrs = Map.put(attrs, "community_id", community.id)

      with {:ok, group} <-
             Repo.transact(fn ->
               with {:ok, group} <- %Group{} |> Group.create_changeset(attrs) |> Repo.insert(),
                    {:ok, _membership} <- insert_membership(group, creator, :owner) do
                 {:ok, %Group{group | community: community}}
               end
             end) do
        audit_group_action(creator, group, "group.created", "created the group")
        {:ok, group}
      end
    end
  end

  @doc """
  Updates group settings. Requires `:manage_group`. The sealed flag is
  never cast (see `Kammer.Groups.Group.update_changeset/2`).
  """
  @spec update_group(User.t(), Group.t(), map()) ::
          {:ok, Group.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_group(%User{} = actor, %Group{} = group, attrs) do
    with :ok <- Authorization.authorize(actor, :manage_group, group),
         {:ok, updated} <- group |> Group.update_changeset(attrs) |> Repo.update() do
      audit_group_action(actor, group, "group.settings_updated", "updated the settings of")
      {:ok, updated}
    end
  end

  @doc """
  Sets whether the member's Home shows this group (ADR 0015). A purely
  personal setting: members change only their own membership, so the
  only requirement is that the membership exists.
  """
  @spec set_show_in_home(User.t(), Group.t(), boolean()) ::
          {:ok, GroupMembership.t()} | {:error, :not_a_member}
  def set_show_in_home(%User{} = user, %Group{} = group, show?) when is_boolean(show?) do
    case Repo.get_by(GroupMembership, group_id: group.id, user_id: user.id) do
      nil ->
        {:error, :not_a_member}

      %GroupMembership{} = membership ->
        membership
        |> Ecto.Changeset.change(show_in_home: show?)
        |> Repo.update()
    end
  end

  @doc """
  Updates the group's feature toggles (ADR 0016). Group admins only;
  the changeset forces the feed on. Disabling hides — it never deletes.
  """
  @spec update_group_features(User.t(), Group.t(), [atom() | String.t()]) ::
          {:ok, Group.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_group_features(%User{} = actor, %Group{} = group, features) when is_list(features) do
    with :ok <- Authorization.authorize(actor, :manage_group, group) do
      features =
        Enum.map(features, fn
          feature when is_atom(feature) -> feature
          feature when is_binary(feature) -> safe_feature_atom(feature)
        end)
        |> Enum.reject(&is_nil/1)

      with {:ok, updated} <-
             group |> Group.features_changeset(%{features: features}) |> Repo.update() do
        audit_group_action(actor, group, "group.features_updated", "updated the features of")
        {:ok, updated}
      end
    end
  end

  defp safe_feature_atom(feature) do
    Enum.find(Group.features(), fn known -> Atom.to_string(known) == feature end)
  end

  @doc """
  Archives a group (read-only, hidden from active lists — SPEC §3).
  """
  @spec archive_group(User.t(), Group.t()) ::
          {:ok, Group.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def archive_group(%User{} = actor, %Group{} = group) do
    with :ok <- Authorization.authorize(actor, :archive_group, group),
         {:ok, updated} <-
           group |> Group.archive_changeset(DateTime.utc_now(:second)) |> Repo.update() do
      audit_group_action(actor, group, "group.archived", "archived the group")
      {:ok, updated}
    end
  end

  @doc """
  Unarchives a group.
  """
  @spec unarchive_group(User.t(), Group.t()) ::
          {:ok, Group.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def unarchive_group(%User{} = actor, %Group{} = group) do
    with :ok <- Authorization.authorize(actor, :unarchive_group, group),
         {:ok, updated} <- group |> Group.archive_changeset(nil) |> Repo.update() do
      audit_group_action(actor, group, "group.unarchived", "unarchived the group")
      {:ok, updated}
    end
  end

  @doc """
  Deletes a group outright. Group owners — and community admins, whose
  sole power over sealed groups this is (ADR 0005).
  """
  @spec delete_group(User.t(), Group.t()) ::
          {:ok, Group.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def delete_group(%User{} = actor, %Group{} = group) do
    with :ok <- Authorization.authorize(actor, :delete_group, group) do
      audit_group_action(actor, group, "group.deleted", "deleted the group")
      Repo.delete(group)
    end
  end

  @doc """
  Returns a changeset for group forms.
  """
  @spec change_group(Group.t(), map()) :: Ecto.Changeset.t()
  def change_group(%Group{} = group, attrs \\ %{}) do
    if is_nil(group.id) do
      Group.create_changeset(group, attrs)
    else
      Group.update_changeset(group, attrs)
    end
  end

  ## Membership lifecycle

  @doc """
  The user's membership in the group, or `nil`.
  """
  @spec get_membership(Group.t(), User.t() | nil) :: GroupMembership.t() | nil
  def get_membership(%Group{}, nil), do: nil

  def get_membership(%Group{} = group, %User{} = user) do
    Repo.get_by(GroupMembership, group_id: group.id, user_id: user.id)
  end

  @doc """
  The membership of the given user id in the group, with the user
  preloaded, or `nil`. Invalid ids read as `nil`.
  """
  @spec get_membership_by_user_id(Group.t(), String.t()) :: GroupMembership.t() | nil
  def get_membership_by_user_id(%Group{} = group, user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, uuid} ->
        Repo.one(
          from(membership in GroupMembership,
            where: membership.group_id == ^group.id and membership.user_id == ^uuid,
            preload: :user
          )
        )

      :error ->
        nil
    end
  end

  @doc """
  Joins an open group directly. Requires `:join_group`.
  """
  @spec join_group(User.t(), Group.t()) ::
          {:ok, GroupMembership.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def join_group(%User{} = user, %Group{} = group) do
    with :ok <- Authorization.authorize(user, :join_group, group) do
      insert_membership(group, user, :member)
    end
  end

  @doc """
  Adds a member directly, bypassing the join policy — used by invite
  redemption and join-request approval. Group members must be community
  members; that invariant is enforced here.
  """
  @spec add_member(Group.t(), User.t(), GroupMembership.role()) ::
          {:ok, GroupMembership.t()}
          | {:error, Ecto.Changeset.t() | :banned | :instance_banned}
  def add_member(%Group{} = group, %User{} = user, role \\ :member) do
    group = Repo.preload(group, :community)

    Repo.transact(fn ->
      with {:ok, _community_membership} <-
             Kammer.Communities.add_member(group.community, user),
           {:ok, membership} <- get_or_insert_membership(group, user, role) do
        {:ok, membership}
      end
    end)
  end

  @doc """
  Leaves a group. Owners must transfer ownership first.
  """
  @spec leave_group(User.t(), Group.t()) ::
          {:ok, GroupMembership.t()} | {:error, :not_a_member | :owner_cannot_leave}
  def leave_group(%User{} = user, %Group{} = group) do
    case get_membership(group, user) do
      nil -> {:error, :not_a_member}
      %GroupMembership{role: :owner} -> {:error, :owner_cannot_leave}
      %GroupMembership{} = membership -> Repo.delete(membership)
    end
  end

  @doc """
  Removes a member from the group. Owners cannot be removed (transfer
  ownership first); members may remove themselves (same as leaving);
  otherwise requires `:manage_group`.
  """
  @spec remove_member(User.t(), Group.t(), GroupMembership.t()) ::
          {:ok, GroupMembership.t()} | {:error, :unauthorized | :owner_cannot_leave}
  def remove_member(%User{} = actor, %Group{} = group, %GroupMembership{} = membership) do
    cond do
      membership.role == :owner ->
        {:error, :owner_cannot_leave}

      membership.user_id == actor.id ->
        Repo.delete(membership)

      Authorization.can?(actor, :manage_group, group) ->
        with {:ok, removed} <- Repo.delete(membership) do
          target = Repo.get!(User, membership.user_id)

          audit_group_action(
            actor,
            group,
            "group_member.removed",
            "removed #{target.display_name} from"
          )

          {:ok, removed}
        end

      true ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Removes every group membership `user_id` holds within `community` —
  the group half of `Communities.remove_member/3`'s community removal
  (which cascades across every group in the community, not just one).
  Unauthenticated: callers own the authorization decision.
  """
  @spec remove_memberships_in_community(Community.t(), Ecto.UUID.t()) ::
          {non_neg_integer(), nil}
  def remove_memberships_in_community(%Community{} = community, user_id) do
    Repo.delete_all(
      from(membership in GroupMembership,
        join: group in assoc(membership, :group),
        where: group.community_id == ^community.id and membership.user_id == ^user_id
      )
    )
  end

  @doc """
  Lists group members with profiles. Requires `:view_group`.
  """
  @spec list_members(User.t() | nil, Group.t()) ::
          {:ok, [GroupMembership.t()]} | {:error, :unauthorized}
  def list_members(actor, %Group{} = group) do
    with :ok <- Authorization.authorize(actor, :view_group, group) do
      {:ok,
       Repo.all(
         from(membership in GroupMembership,
           where: membership.group_id == ^group.id,
           join: user in assoc(membership, :user),
           preload: [user: user],
           order_by: user.display_name
         )
       )}
    end
  end

  @doc """
  Changes a member's group role. Requires `:manage_group`; granting or
  revoking Owner additionally requires the actor to be group Owner (or a
  community admin on an unsealed group).
  """
  @spec update_member_role(User.t(), Group.t(), GroupMembership.t(), atom()) ::
          {:ok, GroupMembership.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_member_role(%User{} = actor, %Group{} = group, membership, new_role) do
    actor_relationship = Authorization.relationship(actor, group)

    owner_transition? = new_role == :owner or membership.role == :owner

    owner_powers? =
      actor_relationship.group_role == :owner or
        (actor_relationship.community_role in [:owner, :admin] and not group.sealed)

    authorized? =
      Authorization.can?(actor, :manage_group, group, actor_relationship) and
        (not owner_transition? or owner_powers?)

    if authorized? do
      previous_role = membership.role

      with {:ok, updated} <-
             membership |> GroupMembership.changeset(%{role: new_role}) |> Repo.update() do
        target = Repo.get!(User, membership.user_id)
        override? = is_nil(actor_relationship.group_role)

        audit_group_action(
          actor,
          group,
          "group_member.role_changed",
          "changed #{target.display_name}'s role from #{previous_role} to #{new_role} in",
          %{"override" => override?}
        )

        {:ok, updated}
      end
    else
      {:error, :unauthorized}
    end
  end

  ## Join requests (request_approval policy)

  @doc """
  Requests to join a group with the `request_approval` policy. Requires
  `:request_to_join_group`.
  """
  @spec request_to_join(User.t(), Group.t(), String.t() | nil) ::
          {:ok, GroupJoinRequest.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def request_to_join(%User{} = user, %Group{} = group, message \\ nil) do
    with :ok <- Authorization.authorize(user, :request_to_join_group, group) do
      %GroupJoinRequest{}
      |> GroupJoinRequest.changeset(%{group_id: group.id, user_id: user.id, message: message})
      |> Repo.insert()
    end
  end

  @doc """
  Whether the user has a pending join request for the group.
  """
  @spec pending_join_request?(User.t() | nil, Group.t()) :: boolean()
  def pending_join_request?(nil, %Group{}), do: false

  def pending_join_request?(%User{} = user, %Group{} = group) do
    Repo.exists?(
      from(join_request in GroupJoinRequest,
        where:
          join_request.group_id == ^group.id and join_request.user_id == ^user.id and
            join_request.status == :pending
      )
    )
  end

  @doc """
  One of the group's pending join requests by id, with the requesting
  user preloaded, or `nil`. Invalid or foreign ids read as `nil`;
  callers own the authorization decision (approve/deny re-check).
  """
  @spec get_pending_join_request(Group.t(), String.t()) :: GroupJoinRequest.t() | nil
  def get_pending_join_request(%Group{} = group, request_id) do
    case Ecto.UUID.cast(request_id) do
      {:ok, uuid} ->
        Repo.one(
          from(join_request in GroupJoinRequest,
            where:
              join_request.id == ^uuid and join_request.group_id == ^group.id and
                join_request.status == :pending,
            preload: :user
          )
        )

      :error ->
        nil
    end
  end

  @doc """
  Pending join requests for a group. Requires `:approve_group_members`.
  """
  @spec list_pending_join_requests(User.t(), Group.t()) ::
          {:ok, [GroupJoinRequest.t()]} | {:error, :unauthorized}
  def list_pending_join_requests(%User{} = actor, %Group{} = group) do
    with :ok <- Authorization.authorize(actor, :approve_group_members, group) do
      {:ok,
       Repo.all(
         from(join_request in GroupJoinRequest,
           where: join_request.group_id == ^group.id and join_request.status == :pending,
           join: user in assoc(join_request, :user),
           preload: [user: user],
           order_by: join_request.inserted_at
         )
       )}
    end
  end

  @doc """
  Approves a pending join request, creating the membership.
  """
  @spec approve_join_request(User.t(), Group.t(), GroupJoinRequest.t()) ::
          {:ok, GroupMembership.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :banned | :instance_banned}
  def approve_join_request(%User{} = actor, %Group{} = group, %GroupJoinRequest{} = request) do
    with :ok <- Authorization.authorize(actor, :approve_group_members, group) do
      Repo.transact(fn ->
        with {:ok, _updated_request} <-
               request |> Ecto.Changeset.change(status: :approved) |> Repo.update(),
             {:ok, membership} <- add_member(group, Repo.get!(User, request.user_id)) do
          {:ok, membership}
        end
      end)
    end
  end

  @doc """
  Denies a pending join request.
  """
  @spec deny_join_request(User.t(), Group.t(), GroupJoinRequest.t()) ::
          {:ok, GroupJoinRequest.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def deny_join_request(%User{} = actor, %Group{} = group, %GroupJoinRequest{} = request) do
    with :ok <- Authorization.authorize(actor, :approve_group_members, group) do
      request
      |> Ecto.Changeset.change(status: :denied)
      |> Repo.update()
    end
  end

  ## Internals

  # Community_id is loaded fresh rather than trusting a possibly-stale
  # preload — audit entries are cheap, correctness on the community FK
  # is not optional.
  defp audit_group_action(actor, %Group{} = group, action, verb_phrase, metadata \\ %{}) do
    community_id = group.community_id || Repo.get!(Group, group.id).community_id

    Audit.record(
      community_id,
      actor,
      action,
      "#{actor.display_name} #{verb_phrase} #{group.name}",
      metadata
    )
  end

  defp get_or_insert_membership(%Group{} = group, %User{} = user, role) do
    case get_membership(group, user) do
      nil -> insert_membership(group, user, role)
      %GroupMembership{} = existing_membership -> {:ok, existing_membership}
    end
  end

  defp insert_membership(%Group{} = group, %User{} = user, role) do
    %GroupMembership{}
    |> GroupMembership.changeset(%{group_id: group.id, user_id: user.id, role: role})
    |> Repo.insert()
  end
end
