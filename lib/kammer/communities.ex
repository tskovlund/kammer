defmodule Kammer.Communities do
  @moduledoc """
  Communities: the multi-tenant unit (SPEC §3), their memberships and
  roles, instance-level settings, and per-user cross-instance bookmarks.

  All permission decisions are delegated to `Kammer.Authorization`.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Audit
  alias Kammer.Authorization
  alias Kammer.Communities.Community
  alias Kammer.Communities.CommunityMembership
  alias Kammer.Communities.CustomField
  alias Kammer.Communities.CustomFieldValue
  alias Kammer.Communities.InstanceBookmark
  alias Kammer.Communities.InstanceSettings
  alias Kammer.Groups
  alias Kammer.Repo

  ## Instance settings

  @doc """
  Returns the singleton instance settings row, creating it with defaults on
  first access.
  """
  @spec get_instance_settings() :: InstanceSettings.t()
  def get_instance_settings do
    Repo.one(from(settings in InstanceSettings, limit: 1)) ||
      Repo.insert!(%InstanceSettings{}, on_conflict: :nothing, conflict_target: :singleton_guard) ||
      Repo.one!(from(settings in InstanceSettings, limit: 1))
  end

  @doc """
  Updates instance settings. Only instance operators may do this.
  """
  @spec update_instance_settings(User.t(), map()) ::
          {:ok, InstanceSettings.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_instance_settings(%User{} = actor, attrs) do
    if Authorization.instance_operator?(actor) do
      get_instance_settings()
      |> InstanceSettings.changeset(attrs)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Builds a changeset for editing instance settings, for form rendering.
  """
  @spec change_instance_settings(InstanceSettings.t(), map()) :: Ecto.Changeset.t()
  def change_instance_settings(%InstanceSettings{} = settings, attrs \\ %{}) do
    InstanceSettings.changeset(settings, attrs)
  end

  ## Communities

  @doc """
  Fetches a community by id, or `nil` if it doesn't exist.
  Unauthenticated — callers pass the result to an authorization-checked
  mutator, or use it for display only.
  """
  @spec get_community(Ecto.UUID.t()) :: Community.t() | nil
  def get_community(community_id), do: Repo.get(Community, community_id)

  @doc """
  Gets a community by slug, or `nil`.
  """
  @spec get_community_by_slug(String.t()) :: Community.t() | nil
  def get_community_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Community, slug: slug)
  end

  @doc """
  Gets a community by slug, raising if absent.
  """
  @spec get_community_by_slug!(String.t()) :: Community.t()
  def get_community_by_slug!(slug) when is_binary(slug) do
    Repo.get_by!(Community, slug: slug)
  end

  @doc """
  Creates a community; the creator becomes its Owner (SPEC §3). Authorized
  against the instance community-creation policy, and refused for
  instance-banned creators — an instance ban is an email-keyed rejoin
  block the creator's live session survives, and becoming a community
  owner is exactly the protected state the ban guards exist to prevent
  (issue #172).
  """
  @spec create_community(User.t(), map()) ::
          {:ok, Community.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_community(%User{} = creator, attrs) do
    settings = get_instance_settings()

    if Authorization.can_create_community?(creator, settings) do
      Repo.transact(fn ->
        # Same user-row lock (and current-email re-read) as
        # `add_member/3`, for the same reason: ban-vs-create serializes
        # against the ban paths, which take this lock first (#170/#172).
        email = Kammer.Accounts.lock_user_email(creator) || creator.email

        if Kammer.Moderation.instance_banned?(email) do
          {:error, :unauthorized}
        else
          with {:ok, community} <-
                 %Community{} |> Community.changeset(attrs) |> Repo.insert(),
               {:ok, _membership} <- insert_membership(community, creator, :owner) do
            {:ok, community}
          end
        end
      end)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Updates a community's settings (name, accent, policies). Requires
  `:manage_community`.
  """
  @spec update_community(User.t(), Community.t(), map()) ::
          {:ok, Community.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_community(%User{} = actor, %Community{} = community, attrs) do
    with :ok <- Authorization.authorize(actor, :manage_community, community),
         {:ok, updated} <- community |> Community.changeset(attrs) |> Repo.update() do
      Audit.record(
        community,
        actor,
        "community.settings_updated",
        "#{actor.display_name} updated the community settings"
      )

      {:ok, updated}
    end
  end

  @doc """
  Returns a changeset for community forms.
  """
  @spec change_community(Community.t(), map()) :: Ecto.Changeset.t()
  def change_community(%Community{} = community, attrs \\ %{}) do
    Community.changeset(community, attrs)
  end

  @doc """
  All communities the user belongs to, for the switcher — ordered by name.
  """
  @spec list_user_communities(User.t()) :: [Community.t()]
  def list_user_communities(%User{} = user) do
    Repo.all(
      from(community in Community,
        join: membership in CommunityMembership,
        on: membership.community_id == community.id,
        where: membership.user_id == ^user.id,
        order_by: community.name
      )
    )
  end

  @doc """
  Communities that opted into the instance landing page
  (SPEC §3: `listed_on_instance`, default off).
  """
  @spec list_public_communities() :: [Community.t()]
  def list_public_communities do
    Repo.all(
      from(community in Community,
        where: community.listed_on_instance == true,
        order_by: community.name
      )
    )
  end

  ## Memberships

  @doc """
  The user's membership in the community, or `nil`.
  """
  @spec get_membership(Community.t(), User.t() | nil) :: CommunityMembership.t() | nil
  def get_membership(%Community{}, nil), do: nil

  def get_membership(%Community{} = community, %User{} = user) do
    Repo.get_by(CommunityMembership, community_id: community.id, user_id: user.id)
  end

  @doc """
  Adds a user to a community with the given role. Idempotent: an existing
  membership is returned unchanged. Intended for invite redemption and
  internal flows — there is no open "join community" in v1 (communities are
  entered by invitation, SPEC §3). The ban checks run inside a transaction
  against the row-locked user, so a ban and a join of the same user
  serialize instead of racing (issue #170).
  """
  @spec add_member(Community.t(), User.t(), CommunityMembership.role()) ::
          {:ok, CommunityMembership.t()}
          | {:error, Ecto.Changeset.t() | :banned | :instance_banned}
  def add_member(%Community{} = community, %User{} = user, role \\ :member) do
    Repo.transact(fn ->
      # Lock the user's row before the ban checks — the first lock both
      # of `Kammer.Moderation`'s ban paths take (user row, then
      # membership rows, #129/#171) — so ban-vs-join serializes instead
      # of racing (issue #170): a concurrent ban either committed
      # before this lock was granted (the checks below see it) or
      # blocks on it until this membership commits (its purge then
      # removes the membership). Deadlock-safe: no transaction locks a
      # membership row before a user row, and the locks callers may
      # already hold when they reach this (the invite row in
      # redeem_invite, the join-request row in approve_join_request —
      # Ecto flattens nested transactions) are only ever acquired
      # BEFORE user locks, never after, so no cycle exists through
      # them either. The locked re-read also keeps the ban checks
      # keyed on the user's current email, not the caller's possibly
      # stale struct.
      email = Kammer.Accounts.lock_user_email(user) || user.email

      cond do
        # The single choke-point for bans (SPEC §11): instance-wide first,
        # then the per-community list — banned emails cannot rejoin
        # through any invite.
        Kammer.Moderation.instance_banned?(email) ->
          {:error, :instance_banned}

        Kammer.Moderation.banned?(community, email) ->
          {:error, :banned}

        membership = get_membership(community, user) ->
          {:ok, membership}

        true ->
          insert_membership(community, user, role)
      end
    end)
  end

  @doc """
  Lists members with their user profile, for the member directory
  (SPEC §4). Requires `:view_member_directory`.
  """
  @spec list_members(User.t() | nil, Community.t()) ::
          {:ok, [CommunityMembership.t()]} | {:error, :unauthorized}
  def list_members(actor, %Community{} = community) do
    with :ok <- Authorization.authorize(actor, :view_member_directory, community) do
      {:ok,
       Repo.all(
         from(membership in CommunityMembership,
           where: membership.community_id == ^community.id,
           join: user in assoc(membership, :user),
           preload: [user: user],
           order_by: user.display_name
         )
       )}
    end
  end

  @doc """
  Changes a member's community role. Requires `:manage_community`; granting
  or revoking the Owner role additionally requires the actor to be Owner.
  """
  @spec update_member_role(User.t(), Community.t(), CommunityMembership.t(), atom()) ::
          {:ok, CommunityMembership.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_member_role(
        %User{} = actor,
        %Community{} = community,
        %CommunityMembership{} = membership,
        new_role
      ) do
    actor_relationship = Authorization.relationship(actor, community)

    owner_transition? = new_role == :owner or membership.role == :owner

    authorized? =
      Authorization.can?(actor, :manage_community, community, actor_relationship) and
        (not owner_transition? or actor_relationship.community_role == :owner)

    if authorized? do
      previous_role = membership.role

      with {:ok, updated} <-
             membership |> CommunityMembership.changeset(%{role: new_role}) |> Repo.update() do
        target = Repo.get!(User, membership.user_id)

        Audit.record(
          community,
          actor,
          "member.role_changed",
          "#{actor.display_name} changed #{target.display_name}'s role from " <>
            "#{previous_role} to #{new_role}"
        )

        {:ok, updated}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Removes a member from the community (and all its groups). Owners cannot
  be removed. Members may remove themselves (leave); otherwise requires
  `:manage_community`.
  """
  @spec remove_member(User.t(), Community.t(), CommunityMembership.t()) ::
          {:ok, CommunityMembership.t()} | {:error, :unauthorized | :owner_cannot_leave}
  def remove_member(%User{} = actor, %Community{} = community, membership) do
    cond do
      membership.role == :owner ->
        {:error, :owner_cannot_leave}

      membership.user_id == actor.id or
          Authorization.can?(actor, :manage_community, community) ->
        target = Repo.get!(User, membership.user_id)

        with {:ok, removed} <-
               Repo.transact(fn ->
                 # Community-membership row before group rows — the
                 # global lock order every membership-removing
                 # transaction follows (Moderation's ban paths lock the
                 # community row first, #129); the reverse order here
                 # would deadlock a concurrent ban + remove of the same
                 # member.
                 with {:ok, removed} <- Repo.delete(membership) do
                   Groups.remove_memberships_in_community(community, membership.user_id)
                   {:ok, removed}
                 end
               end) do
          if actor.id != target.id do
            Audit.record(
              community,
              actor,
              "member.removed",
              "#{actor.display_name} removed #{target.display_name} from the community"
            )
          end

          {:ok, removed}
        end

      true ->
        {:error, :unauthorized}
    end
  end

  defp insert_membership(%Community{} = community, %User{} = user, role) do
    %CommunityMembership{}
    |> CommunityMembership.changeset(%{
      community_id: community.id,
      user_id: user.id,
      role: role
    })
    |> Repo.insert()
  end

  ## Custom profile fields (SPEC §4 — the roster)

  @doc """
  Lists a community's custom profile fields, in display order.
  """
  @spec list_custom_fields(Community.t()) :: [CustomField.t()]
  def list_custom_fields(%Community{} = community) do
    Repo.all(
      from(field in CustomField,
        where: field.community_id == ^community.id,
        order_by: [asc: field.position, asc: field.inserted_at]
      )
    )
  end

  @doc """
  Builds a changeset for a custom field, for form rendering.
  """
  @spec change_custom_field(CustomField.t(), map()) :: Ecto.Changeset.t()
  def change_custom_field(%CustomField{} = custom_field, attrs \\ %{}) do
    CustomField.changeset(custom_field, attrs)
  end

  @doc """
  Creates a custom profile field. Requires `:manage_community`.
  """
  @spec create_custom_field(User.t(), Community.t(), map()) ::
          {:ok, CustomField.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_custom_field(%User{} = actor, %Community{} = community, attrs) do
    if Authorization.can?(actor, :manage_community, community) do
      %CustomField{}
      |> CustomField.changeset(Map.put(attrs, "community_id", community.id))
      |> Repo.insert()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Updates a custom profile field — e.g. making it required after
  members have already joined. That never locks anyone out: it just
  starts surfacing them in `missing_required_custom_fields/2`, which
  drives a nag banner, not a hard block (that only applies at join).
  Requires `:manage_community`.
  """
  @spec update_custom_field(User.t(), Community.t(), CustomField.t(), map()) ::
          {:ok, CustomField.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_custom_field(
        %User{} = actor,
        %Community{} = community,
        %CustomField{} = custom_field,
        attrs
      ) do
    if Authorization.can?(actor, :manage_community, community) do
      custom_field
      |> CustomField.changeset(Map.put(attrs, "community_id", community.id))
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Deletes a custom profile field (and every member's answer to it).
  Requires `:manage_community`.
  """
  @spec delete_custom_field(User.t(), Community.t(), CustomField.t()) ::
          {:ok, CustomField.t()} | {:error, :unauthorized}
  def delete_custom_field(
        %User{} = actor,
        %Community{} = community,
        %CustomField{} = custom_field
      ) do
    if Authorization.can?(actor, :manage_community, community) do
      Repo.delete(custom_field)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  A member's answers to a community's custom fields, keyed by field id.
  """
  @spec get_custom_field_values(Community.t(), User.t()) :: %{optional(binary()) => String.t()}
  def get_custom_field_values(%Community{} = community, %User{} = user) do
    Repo.all(
      from(value in CustomFieldValue,
        join: field in assoc(value, :custom_field),
        where: field.community_id == ^community.id and value.user_id == ^user.id,
        select: {value.custom_field_id, value.value}
      )
    )
    |> Map.new()
  end

  @doc """
  Sets a member's answers to a community's custom fields from a
  `%{field_id => value}` map. A blank value clears that field's answer.
  Values for fields outside this community are ignored.
  """
  @spec put_custom_field_values(User.t(), Community.t(), %{optional(String.t()) => String.t()}) ::
          :ok
  def put_custom_field_values(%User{} = user, %Community{} = community, params) do
    field_ids = community |> list_custom_fields() |> MapSet.new(& &1.id)

    Enum.each(params, fn {field_id, value} ->
      if MapSet.member?(field_ids, field_id) do
        set_custom_field_value(user, field_id, value)
      end
    end)

    :ok
  end

  defp set_custom_field_value(%User{} = user, field_id, value) do
    case value |> to_string() |> String.trim() do
      "" ->
        Repo.delete_all(
          from(value in CustomFieldValue,
            where: value.custom_field_id == ^field_id and value.user_id == ^user.id
          )
        )

      trimmed ->
        %CustomFieldValue{}
        |> CustomFieldValue.changeset(%{
          custom_field_id: field_id,
          user_id: user.id,
          value: String.slice(trimmed, 0, 200)
        })
        |> Repo.insert(
          on_conflict: {:replace, [:value, :updated_at]},
          conflict_target: [:custom_field_id, :user_id]
        )
    end
  end

  @doc """
  Required custom fields a member hasn't answered yet: hard-blocks
  joining (invite redemption) and nags already-joined members when a
  field is made required after the fact — never a lockout.
  """
  @spec missing_required_custom_fields(Community.t(), User.t()) :: [CustomField.t()]
  def missing_required_custom_fields(%Community{} = community, %User{} = user) do
    answered_field_ids =
      community |> get_custom_field_values(user) |> Map.keys() |> MapSet.new()

    community
    |> list_custom_fields()
    |> Enum.filter(&(&1.required and not MapSet.member?(answered_field_ids, &1.id)))
  end

  @doc """
  A community's custom fields the given viewer role is allowed to see
  at all, in display order — used both to render the directory's
  filter controls and to redact `visible_custom_field_values/3`.
  """
  @spec list_visible_custom_fields(Community.t(), CommunityMembership.role() | nil) ::
          [CustomField.t()]
  def list_visible_custom_fields(%Community{} = community, viewer_role) do
    community
    |> list_custom_fields()
    |> Enum.filter(&custom_field_visible?(&1.visibility, viewer_role))
  end

  @doc """
  A target member's custom field answers the given viewer role is
  allowed to see, as `{field, value}` pairs in display order.
  """
  @spec visible_custom_field_values(Community.t(), User.t(), CommunityMembership.role() | nil) ::
          [{CustomField.t(), String.t()}]
  def visible_custom_field_values(%Community{} = community, %User{} = target, viewer_role) do
    values = get_custom_field_values(community, target)

    community
    |> list_visible_custom_fields(viewer_role)
    |> Enum.flat_map(fn field ->
      case Map.fetch(values, field.id) do
        {:ok, value} -> [{field, value}]
        :error -> []
      end
    end)
  end

  @doc """
  Batched form of `get_custom_field_values/2` for many members at
  once (the member directory listing) — one query instead of one per
  member. Keyed by user id, then by field id.
  """
  @spec custom_field_values_by_user(Community.t(), [User.t()]) ::
          %{optional(binary()) => %{optional(binary()) => String.t()}}
  def custom_field_values_by_user(%Community{} = community, users) do
    user_ids = Enum.map(users, & &1.id)

    Repo.all(
      from(value in CustomFieldValue,
        join: field in assoc(value, :custom_field),
        where: field.community_id == ^community.id and value.user_id in ^user_ids,
        select: {value.user_id, value.custom_field_id, value.value}
      )
    )
    |> Enum.group_by(
      fn {user_id, _field_id, _value} -> user_id end,
      fn {_user_id, field_id, value} -> {field_id, value} end
    )
    |> Map.new(fn {user_id, pairs} -> {user_id, Map.new(pairs)} end)
  end

  defp custom_field_visible?(:members, role), do: role in [:owner, :admin, :member]
  defp custom_field_visible?(:admins, role), do: role in [:owner, :admin]

  ## Cross-instance bookmarks ("My other servers", SPEC §3)

  @doc """
  Lists the user's cross-instance bookmarks in position order.
  """
  @spec list_instance_bookmarks(User.t()) :: [InstanceBookmark.t()]
  def list_instance_bookmarks(%User{} = user) do
    Repo.all(
      from(bookmark in InstanceBookmark,
        where: bookmark.user_id == ^user.id,
        order_by: [bookmark.position, bookmark.inserted_at]
      )
    )
  end

  @doc """
  Creates a bookmark for the user.
  """
  @spec create_instance_bookmark(User.t(), map()) ::
          {:ok, InstanceBookmark.t()} | {:error, Ecto.Changeset.t()}
  def create_instance_bookmark(%User{} = user, attrs) do
    %InstanceBookmark{user_id: user.id}
    |> InstanceBookmark.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes one of the user's own bookmarks.
  """
  @spec delete_instance_bookmark(User.t(), Ecto.UUID.t()) :: :ok
  def delete_instance_bookmark(%User{} = user, bookmark_id) do
    Repo.delete_all(
      from(bookmark in InstanceBookmark,
        where: bookmark.id == ^bookmark_id and bookmark.user_id == ^user.id
      )
    )

    :ok
  end

  @doc """
  Returns a changeset for bookmark forms.
  """
  @spec change_instance_bookmark(InstanceBookmark.t(), map()) :: Ecto.Changeset.t()
  def change_instance_bookmark(%InstanceBookmark{} = bookmark, attrs \\ %{}) do
    InstanceBookmark.changeset(bookmark, attrs)
  end
end
