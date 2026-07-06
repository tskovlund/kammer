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

  ## Post-level rules (SPEC §5) — pure; the post's group and the actor's
  ## relationship are passed explicitly.

  @doc """
  Whether the actor may edit the post's body. Authors only — admins
  moderate (delete/pin/lock) but never rewrite someone's words.
  """
  @spec can_edit_post?(actor(), map(), Group.t(), relationship()) :: boolean()
  def can_edit_post?(actor, post, %Group{} = group, relationship) do
    author?(actor, post) and is_nil(post.deleted_at) and not Group.archived?(group) and
      (relationship.group_role != nil or group_admin_powers?(group, relationship))
  end

  @doc """
  Whether the actor may soft-delete the post (author) — the stub
  preserves thread coherence (SPEC §5).
  """
  @spec can_soft_delete_post?(actor(), map(), Group.t(), relationship()) :: boolean()
  def can_soft_delete_post?(actor, post, %Group{} = _group, _relationship) do
    author?(actor, post) and is_nil(post.deleted_at)
  end

  @doc """
  Whether the actor may hard-delete the post immediately (admins,
  SPEC §5; GDPR erasure also routes here).
  """
  @spec can_hard_delete_post?(actor(), map(), Group.t(), relationship()) :: boolean()
  def can_hard_delete_post?(_actor, _post, %Group{} = group, relationship) do
    group_admin_powers?(group, relationship)
  end

  @doc """
  Whether the actor may pin/unpin the post.
  """
  @spec can_pin_post?(actor(), map(), Group.t(), relationship()) :: boolean()
  def can_pin_post?(_actor, _post, %Group{} = group, relationship) do
    group_admin_powers?(group, relationship) and not Group.archived?(group)
  end

  @doc """
  Whether the actor may lock/unlock comments on the post — available to
  the author and admins (SPEC §3).
  """
  @spec can_lock_post_comments?(actor(), map(), Group.t(), relationship()) :: boolean()
  def can_lock_post_comments?(actor, post, %Group{} = group, relationship) do
    author?(actor, post) or group_admin_powers?(group, relationship)
  end

  @doc """
  Whether the actor may see who has and hasn't acknowledged the post —
  the author and admins (SPEC §5).
  """
  @spec can_view_acknowledgments?(actor(), map(), Group.t(), relationship()) :: boolean()
  def can_view_acknowledgments?(actor, post, %Group{} = group, relationship) do
    author?(actor, post) or group_admin_powers?(group, relationship)
  end

  @doc """
  Whether the actor may see the post's edit history — the author and
  admins, never the public (SPEC §5).
  """
  @spec can_view_edit_history?(actor(), map(), Group.t(), relationship()) :: boolean()
  def can_view_edit_history?(actor, post, %Group{} = group, relationship) do
    author?(actor, post) or group_admin_powers?(group, relationship)
  end

  @doc """
  Whether the actor may edit or delete the given comment (author for
  both; admins may delete via `:moderate_group`).
  """
  @spec can_edit_comment?(actor(), map(), Group.t(), relationship()) :: boolean()
  def can_edit_comment?(actor, comment, %Group{} = group, _relationship) do
    comment_author?(actor, comment) and is_nil(comment.deleted_at) and
      not Group.archived?(group)
  end

  @doc """
  Whether the actor may react in the group (group members; archived
  groups are read-only).
  """
  @spec can_react?(actor(), Group.t(), relationship()) :: boolean()
  def can_react?(actor, %Group{} = group, relationship) do
    signed_in?(actor) and not Group.archived?(group) and
      (relationship.group_role != nil or group_admin_powers?(group, relationship))
  end

  @doc """
  Whether account-less guests may RSVP to events in this group
  (SPEC §6): only on the public presets, never once archived, and only
  while the events feature is enabled. This is the whole guest-RSVP
  policy — the web layer adds email verification and rate limits, not
  permissions.
  """
  @spec can_guest_rsvp?(Group.t()) :: boolean()
  def can_guest_rsvp?(%Group{} = group) do
    group.visibility in [:public_link, :public_listed] and not Group.archived?(group) and
      Group.feature_enabled?(group, :events)
  end

  @doc """
  The feature gate (ADR 0016): a disabled feature is indistinguishable
  from one the actor may not see — the same `:not_found` surface, so
  toggling leaks nothing. Contexts call this beside `authorize/3` for
  feature-scoped resources (events, group file spaces); the feed is not
  toggleable.
  """
  @spec feature_gate(Group.t(), atom()) :: :ok | {:error, :not_found}
  def feature_gate(%Group{} = group, feature) do
    if Group.feature_enabled?(group, feature), do: :ok, else: {:error, :not_found}
  end

  defp author?(actor, %{author_user_id: author_user_id}) do
    case unwrap_user(actor) do
      %User{id: user_id} -> user_id == author_user_id
      nil -> false
    end
  end

  defp comment_author?(actor, %{author_user_id: author_user_id}) do
    case unwrap_user(actor) do
      %User{id: user_id} -> user_id == author_user_id
      nil -> false
    end
  end

  ## File-space rules (SPEC §7, ADR 0009) — presets only, no ACLs.
  ##
  ## THE INVARIANT (enforced here, property-tested): file/folder visibility
  ## can never exceed the owning scope's visibility preset. Reading always
  ## requires scope view access first; folder overrides can only restrict
  ## further, never widen.

  @typedoc "The owning scope of a file space: a group or the community."
  @type file_scope() :: Group.t() | Community.t()

  @doc """
  Whether the actor may read files in the given folder chain (root-first
  ancestors, innermost last; `[]` for the space root).

  Requires scope view access (`:view_group` / `:view_community`) — the
  invariant — and honors `admins_only` read overrides anywhere in the
  chain (subfolders inherit restrictions from parents).
  """
  @spec can_read_folder?(actor(), file_scope(), [struct()], relationship()) :: boolean()
  def can_read_folder?(actor, scope, folder_chain, relationship) do
    scope_viewable?(actor, scope, relationship) and
      (not chain_restricted?(folder_chain, :read_override) or
         scope_admin_powers?(scope, relationship))
  end

  @doc """
  Whether the actor may write (upload/create folders) in the folder
  chain. Baseline write access is scope membership (SPEC §7:
  `inherit(members)`); `admins_only` write overrides anywhere in the
  chain restrict to admins. Archived groups are read-only.
  """
  @spec can_write_folder?(actor(), file_scope(), [struct()], relationship()) :: boolean()
  def can_write_folder?(actor, scope, folder_chain, relationship) do
    signed_in?(actor) and
      scope_writable_baseline?(scope, relationship) and
      (not chain_restricted?(folder_chain, :write_override) or
         scope_admin_powers?(scope, relationship))
  end

  @doc """
  Whether the actor may manage the file space (folder overrides, deleting
  others' files): scope admin powers.
  """
  @spec can_manage_files?(actor(), file_scope(), relationship()) :: boolean()
  def can_manage_files?(_actor, scope, relationship) do
    scope_admin_powers?(scope, relationship)
  end

  defp scope_viewable?(actor, %Group{} = group, relationship) do
    can?(actor, :view_group, group, relationship)
  end

  defp scope_viewable?(actor, %Community{} = community, relationship) do
    can?(actor, :view_community, community, relationship)
  end

  defp scope_writable_baseline?(%Group{} = group, relationship) do
    not Group.archived?(group) and
      (relationship.group_role != nil or group_admin_powers?(group, relationship))
  end

  defp scope_writable_baseline?(%Community{}, relationship) do
    relationship.community_role != nil
  end

  defp scope_admin_powers?(%Group{} = group, relationship) do
    group_admin_powers?(group, relationship)
  end

  defp scope_admin_powers?(%Community{}, relationship) do
    community_admin?(relationship)
  end

  defp chain_restricted?(folder_chain, override_field) do
    Enum.any?(folder_chain, fn folder -> Map.fetch!(folder, override_field) == :admins_only end)
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
