defmodule Kammer.CommunitiesFixtures do
  @moduledoc """
  Test helpers for creating communities, groups, and memberships.
  """

  import Kammer.AccountsFixtures

  alias Kammer.Communities
  alias Kammer.Communities.Community
  alias Kammer.Communities.CommunityMembership
  alias Kammer.Groups
  alias Kammer.Groups.Group
  alias Kammer.Groups.GroupMembership
  alias Kammer.Repo

  def unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  def community_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Community #{System.unique_integer([:positive])}",
        slug: unique_slug("community")
      })

    %Community{}
    |> Community.changeset(attrs)
    |> Repo.insert!()
  end

  def community_membership_fixture(community, user, role \\ :member) do
    %CommunityMembership{}
    |> CommunityMembership.changeset(%{
      community_id: community.id,
      user_id: user.id,
      role: role
    })
    |> Repo.insert!()
  end

  @doc "Creates a community with an owner user; returns {community, owner}."
  def community_with_owner_fixture(attrs \\ %{}) do
    owner = user_fixture()
    community = community_fixture(attrs)
    community_membership_fixture(community, owner, :owner)
    {community, owner}
  end

  def group_fixture(community, attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{
        name: "Group #{System.unique_integer([:positive])}",
        slug: unique_slug("group"),
        community_id: community.id
      })
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    %Group{}
    |> Group.create_changeset(attrs)
    |> Repo.insert!()
    |> Map.put(:community, community)
  end

  def group_membership_fixture(group, user, role \\ :member) do
    %GroupMembership{}
    |> GroupMembership.changeset(%{group_id: group.id, user_id: user.id, role: role})
    |> Repo.insert!()
  end

  @doc """
  A member of the community (and optionally the group) with the given
  roles. Returns the user.
  """
  def member_fixture(community, community_role \\ :member) do
    user = user_fixture()
    community_membership_fixture(community, user, community_role)
    user
  end

  def group_member_fixture(group, group_role \\ :member) do
    user = user_fixture()
    community_membership_fixture(group.community, user, :member)
    group_membership_fixture(group, user, group_role)
    user
  end

  def instance_operator_fixture do
    user = user_fixture()

    user
    |> Ecto.Changeset.change(instance_operator: true)
    |> Repo.update!()
  end

  def allow_any_user_community_creation do
    settings = Communities.get_instance_settings()

    settings
    |> Ecto.Changeset.change(community_creation_policy: :any_user)
    |> Repo.update!()
  end

  defdelegate list_active_groups(actor, community), to: Groups
end
