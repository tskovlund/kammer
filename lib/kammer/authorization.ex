defmodule Kammer.Authorization do
  @moduledoc """
  The single authorization module (SPEC §17): every permission and
  visibility decision in Kammer flows through here. No inline checks in
  templates, LiveViews, or controllers.

  ## Shape

  Decisions are made by the pure function `can?/4`, which takes the actor's
  `t:relationship/0` to the resource (instance-operator flag, community
  role, group role) explicitly. The convenience `can?/3` loads that
  relationship from the database first. Property-based tests target the
  pure core.

  ## The rules encoded here

  * **Community admins have full override on all groups in their
    community — except sealed groups** (SPEC §3, ADR 0005). For sealed
    groups their sole power is `:delete_group`.
  * **Instance operators get no in-app content access** to communities they
    don't belong to (SPEC §3). The operator flag only matters for
    instance-level actions such as creating communities.
  * **Archived groups are read-only** (SPEC §3): content remains browsable
    per visibility, but nothing can be posted or commented.
  * The four visibility presets (ADR 0004): `private` / `community` /
    `public_link` / `public_listed`. The two public presets are readable
    without an account; `public_link` is excluded from listings.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.Scope
  alias Kammer.Accounts.User
  alias Kammer.Communities.Community
  alias Kammer.Communities.CommunityMembership
  alias Kammer.Communities.InstanceSettings
  alias Kammer.Groups.Group
  alias Kammer.Groups.GroupMembership
  alias Kammer.Repo

  @typedoc "The acting party: a signed-in user, a scope, or anonymous."
  @type actor() :: User.t() | Scope.t() | nil

  @typedoc """
  The actor's relationship to a resource, loaded once and passed to the
  pure decision core.
  """
  @type relationship() :: %{
          instance_operator?: boolean(),
          community_role: CommunityMembership.role() | nil,
          group_role: GroupMembership.role() | nil
        }

  @type group_action() ::
          :view_group
          | :join_group
          | :request_to_join_group
          | :manage_group
          | :archive_group
          | :unarchive_group
          | :delete_group
          | :create_group_invite
          | :approve_group_members
          | :post_in_group
          | :comment_in_group
          | :post_as_group
          | :moderate_group

  @type community_action() ::
          :view_community
          | :view_member_directory
          | :manage_community
          | :delete_community
          | :create_group
          | :create_community_invite

  @type action() :: group_action() | community_action() | :create_community

  @community_admin_roles [:owner, :admin]
  @group_admin_roles [:owner, :admin]

  ## Public API — convenience entry points that load the relationship

  @doc """
  Whether the actor may perform `action` on the resource. Loads the actor's
  relationship from the database, then delegates to the pure `can?/4`.
  """
  @spec can?(actor(), action(), Group.t() | Community.t()) :: boolean()
  def can?(actor, action, resource) do
    can?(actor, action, resource, relationship(actor, resource))
  end

  @doc """
  Like `can?/3` but returns `:ok` or `{:error, :unauthorized}` for use in
  `with` chains.
  """
  @spec authorize(actor(), action(), Group.t() | Community.t()) ::
          :ok | {:error, :unauthorized}
  def authorize(actor, action, resource) do
    if can?(actor, action, resource), do: :ok, else: {:error, :unauthorized}
  end

  @doc """
  Whether the actor may create a community on this instance
  (SPEC §3: instance setting — operators only / any user).
  """
  @spec can_create_community?(actor(), InstanceSettings.t()) :: boolean()
  def can_create_community?(actor, %InstanceSettings{} = settings) do
    case unwrap_user(actor) do
      nil -> false
      %User{instance_operator: true} -> true
      %User{} -> settings.community_creation_policy == :any_user
    end
  end

  ## Pure decision core — property-tested; takes the relationship explicitly

  @doc """
  The pure decision core: answers `action` for a group or community given
  the actor's `relationship`. No database access.
  """
  @spec can?(actor(), action(), Group.t() | Community.t(), relationship()) :: boolean()
  def can?(actor, action, resource, relationship)

  # --- Group visibility -----------------------------------------------------

  def can?(_actor, :view_group, %Group{} = group, relationship) do
    cond do
      group.visibility in [:public_link, :public_listed] -> true
      group.visibility == :community -> relationship.community_role != nil
      group.visibility == :private -> member_or_unsealed_override?(group, relationship)
    end
  end

  # --- Group membership lifecycle -------------------------------------------

  def can?(actor, :join_group, %Group{} = group, relationship) do
    signed_in?(actor) and
      relationship.community_role != nil and
      is_nil(relationship.group_role) and
      not Group.archived?(group) and
      group.join_policy == :open and
      can?(actor, :view_group, group, relationship)
  end

  def can?(actor, :request_to_join_group, %Group{} = group, relationship) do
    signed_in?(actor) and
      relationship.community_role != nil and
      is_nil(relationship.group_role) and
      not Group.archived?(group) and
      group.join_policy == :request_approval and
      can?(actor, :view_group, group, relationship)
  end

  # --- Group administration --------------------------------------------------

  def can?(_actor, :manage_group, %Group{} = group, relationship) do
    group_admin_powers?(group, relationship)
  end

  def can?(_actor, :archive_group, %Group{} = group, relationship) do
    group_admin_powers?(group, relationship)
  end

  def can?(_actor, :unarchive_group, %Group{} = group, relationship) do
    group_admin_powers?(group, relationship)
  end

  def can?(_actor, :delete_group, %Group{} = _group, relationship) do
    # Sole community-admin power that pierces sealing (ADR 0005).
    relationship.group_role == :owner or community_admin?(relationship)
  end

  def can?(_actor, :create_group_invite, %Group{} = group, relationship) do
    group_admin_powers?(group, relationship) and not Group.archived?(group)
  end

  def can?(_actor, :approve_group_members, %Group{} = group, relationship) do
    group_admin_powers?(group, relationship) and not Group.archived?(group)
  end

  # --- Group content actions -------------------------------------------------

  def can?(_actor, :post_in_group, %Group{} = group, relationship) do
    not Group.archived?(group) and
      case group.posting_policy do
        :all_members ->
          relationship.group_role != nil or group_admin_powers?(group, relationship)

        :admins_only ->
          group_admin_powers?(group, relationship)
      end
  end

  def can?(actor, :comment_in_group, %Group{} = group, relationship) do
    not Group.archived?(group) and
      group.comment_policy != :off and
      (relationship.group_role != nil or group_admin_powers?(group, relationship)) and
      signed_in?(actor)
  end

  def can?(actor, :post_as_group, %Group{} = group, relationship) do
    group_admin_powers?(group, relationship) and can?(actor, :post_in_group, group, relationship)
  end

  def can?(_actor, :moderate_group, %Group{} = group, relationship) do
    group_admin_powers?(group, relationship)
  end

  # --- Community actions -----------------------------------------------------

  def can?(_actor, :view_community, %Community{}, relationship) do
    relationship.community_role != nil
  end

  def can?(_actor, :view_member_directory, %Community{}, relationship) do
    relationship.community_role != nil
  end

  def can?(_actor, :manage_community, %Community{}, relationship) do
    community_admin?(relationship)
  end

  def can?(_actor, :delete_community, %Community{}, relationship) do
    relationship.community_role == :owner
  end

  def can?(actor, :create_group, %Community{}, relationship) do
    # Any community member may create a group and becomes its owner
    # (recorded in BUILDLOG: SPEC is silent; boring default chosen).
    signed_in?(actor) and relationship.community_role != nil
  end

  def can?(_actor, :create_community_invite, %Community{}, relationship) do
    community_admin?(relationship)
  end

  ## Listing / query scoping — the only place list filtering logic lives

  @doc """
  All groups of a community the actor should see in listings.

  Note `public_link` groups are viewable via direct link (`:view_group`)
  but excluded from listings unless the actor is a member or has unsealed
  admin override — that is what "unlisted" means (SPEC §3).
  """
  @spec listable_groups_query(actor(), Community.t()) :: Ecto.Query.t()
  def listable_groups_query(actor, %Community{} = community) do
    base_query = from(group in Group, where: group.community_id == ^community.id)

    case unwrap_user(actor) do
      nil ->
        from(group in base_query, where: group.visibility == :public_listed)

      %User{} = user ->
        community_relationship = relationship(user, community)

        cond do
          community_admin?(community_relationship) ->
            # Full override except sealed: sealed groups appear only if member.
            from(group in base_query,
              left_join: membership in GroupMembership,
              on: membership.group_id == group.id and membership.user_id == ^user.id,
              where: group.sealed == false or not is_nil(membership.id)
            )

          community_relationship.community_role != nil ->
            from(group in base_query,
              left_join: membership in GroupMembership,
              on: membership.group_id == group.id and membership.user_id == ^user.id,
              where:
                group.visibility in [:community, :public_listed] or
                  not is_nil(membership.id)
            )

          true ->
            from(group in base_query, where: group.visibility == :public_listed)
        end
    end
  end

  ## Relationship loading

  @doc """
  Loads the actor's relationship (instance-operator flag, community role,
  group role) to a group or community in single indexed lookups.
  """
  @spec relationship(actor(), Group.t() | Community.t()) :: relationship()
  def relationship(actor, resource) do
    case unwrap_user(actor) do
      nil ->
        %{instance_operator?: false, community_role: nil, group_role: nil}

      %User{} = user ->
        {community_id, group_id} =
          case resource do
            %Group{} = group -> {group.community_id, group.id}
            %Community{} = community -> {community.id, nil}
          end

        %{
          instance_operator?: user.instance_operator,
          community_role: lookup_community_role(user.id, community_id),
          group_role: group_id && lookup_group_role(user.id, group_id)
        }
    end
  end

  defp lookup_community_role(user_id, community_id) do
    Repo.one(
      from(membership in CommunityMembership,
        where: membership.user_id == ^user_id and membership.community_id == ^community_id,
        select: membership.role
      )
    )
  end

  defp lookup_group_role(user_id, group_id) do
    Repo.one(
      from(membership in GroupMembership,
        where: membership.user_id == ^user_id and membership.group_id == ^group_id,
        select: membership.role
      )
    )
  end

  ## Shared rule fragments

  defp community_admin?(relationship) do
    relationship.community_role in @community_admin_roles
  end

  defp group_admin_powers?(%Group{} = group, relationship) do
    relationship.group_role in @group_admin_roles or
      (community_admin?(relationship) and not group.sealed)
  end

  defp member_or_unsealed_override?(%Group{} = group, relationship) do
    relationship.group_role != nil or
      (community_admin?(relationship) and not group.sealed)
  end

  defp signed_in?(nil), do: false
  defp signed_in?(%Scope{user: nil}), do: false
  defp signed_in?(%Scope{user: %User{}}), do: true
  defp signed_in?(%User{}), do: true

  defp unwrap_user(nil), do: nil
  defp unwrap_user(%Scope{user: user}), do: user
  defp unwrap_user(%User{} = user), do: user
end
