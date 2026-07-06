defmodule Kammer.Communities do
  @moduledoc """
  Communities: the multi-tenant unit (SPEC §3), their memberships and
  roles, instance-level settings, and per-user cross-instance bookmarks.

  All permission decisions are delegated to `Kammer.Authorization`.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Authorization
  alias Kammer.Communities.Community
  alias Kammer.Communities.CommunityMembership
  alias Kammer.Communities.InstanceBookmark
  alias Kammer.Communities.InstanceSettings
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
  def update_instance_settings(%User{instance_operator: true}, attrs) do
    get_instance_settings()
    |> InstanceSettings.changeset(attrs)
    |> Repo.update()
  end

  def update_instance_settings(%User{}, _attrs), do: {:error, :unauthorized}

  ## Communities

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
  against the instance community-creation policy.
  """
  @spec create_community(User.t(), map()) ::
          {:ok, Community.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_community(%User{} = creator, attrs) do
    settings = get_instance_settings()

    if Authorization.can_create_community?(creator, settings) do
      Repo.transact(fn ->
        with {:ok, community} <-
               %Community{} |> Community.changeset(attrs) |> Repo.insert(),
             {:ok, _membership} <- insert_membership(community, creator, :owner) do
          {:ok, community}
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
    with :ok <- Authorization.authorize(actor, :manage_community, community) do
      community
      |> Community.changeset(attrs)
      |> Repo.update()
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
  entered by invitation, SPEC §3).
  """
  @spec add_member(Community.t(), User.t(), CommunityMembership.role()) ::
          {:ok, CommunityMembership.t()} | {:error, Ecto.Changeset.t() | :banned}
  def add_member(%Community{} = community, %User{} = user, role \\ :member) do
    cond do
      # The single choke-point for community bans (SPEC §11): banned
      # emails cannot rejoin through any invite.
      Kammer.Moderation.banned?(community, user.email) ->
        {:error, :banned}

      membership = get_membership(community, user) ->
        {:ok, membership}

      true ->
        insert_membership(community, user, role)
    end
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
      membership
      |> CommunityMembership.changeset(%{role: new_role})
      |> Repo.update()
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
        Repo.transact(fn ->
          delete_group_memberships_in_community(community, membership.user_id)
          Repo.delete(membership)
        end)

      true ->
        {:error, :unauthorized}
    end
  end

  defp delete_group_memberships_in_community(%Community{} = community, user_id) do
    Repo.delete_all(
      from(group_membership in Kammer.Groups.GroupMembership,
        join: group in assoc(group_membership, :group),
        where: group.community_id == ^community.id and group_membership.user_id == ^user_id
      )
    )
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
