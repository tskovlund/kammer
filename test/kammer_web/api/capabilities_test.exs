defmodule KammerWeb.Api.CapabilitiesTest do
  @moduledoc """
  The `viewer_can` capability list (issue #199): the API tells each
  client which controls to show, computed from the same
  `Kammer.Authorization` decisions the controllers enforce. These tests
  pin the contract that matters — a capability is present IFF the
  corresponding action would actually succeed — across posts, groups,
  and communities, for members, moderators, and outsiders.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers

  alias Kammer.AccountsFixtures
  alias Kammer.Authorization
  alias Kammer.Feed
  alias KammerWeb.Api.Serializer

  defp context(_tags) do
    {community, owner} = community_with_owner_fixture()
    group = group_fixture(community)
    member = group_member_fixture(group)
    admin = group_member_fixture(group, :admin)
    %{community: community, owner: owner, group: group, member: member, admin: admin}
  end

  defp feed(user, community, group) do
    user
    |> api_conn()
    |> get(~p"/api/v1/communities/#{community.slug}/groups/#{group.slug}/posts")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp groups(user, community) do
    user
    |> api_conn()
    |> get(~p"/api/v1/communities/#{community.slug}/groups")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp communities(user) do
    user
    |> api_conn()
    |> get(~p"/api/v1/communities")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  describe "post viewer_can" do
    setup :context

    test "the author may edit/delete but not pin/moderate", %{
      community: community,
      group: group,
      member: member
    } do
      {:ok, _post} = Feed.create_post(member, group, %{"body_markdown" => "Mit indlæg"})

      [post] = feed(member, community, group)

      assert "edit" in post["viewer_can"]
      assert "delete" in post["viewer_can"]
      refute "pin" in post["viewer_can"]
      refute "moderate" in post["viewer_can"]
    end

    test "a moderator may pin/moderate/delete but not edit another's post", %{
      community: community,
      group: group,
      member: member,
      admin: admin
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "Andres indlæg"})

      [serialized] = feed(admin, community, group)

      assert "pin" in serialized["viewer_can"]
      assert "moderate" in serialized["viewer_can"]
      assert "delete" in serialized["viewer_can"]
      refute "edit" in serialized["viewer_can"]

      # IFF enforcement: what the list claims is exactly what the pure
      # authorization core permits.
      relationship = Authorization.relationship(admin, group)
      can = serialized["viewer_can"]

      assert "pin" in can == Authorization.can_pin_post?(admin, post, group, relationship)
      assert "edit" in can == Authorization.can_edit_post?(admin, post, group, relationship)
    end

    test "an outsider on a public group gets an empty post capability set", %{
      community: community
    } do
      public = group_fixture(community, visibility: :public_listed)
      poster = group_member_fixture(public)
      {:ok, _post} = Feed.create_post(poster, public, %{"body_markdown" => "Offentligt"})

      outsider = AccountsFixtures.user_fixture()

      [post] = feed(outsider, community, public)
      assert post["viewer_can"] == []
    end
  end

  describe "group viewer_can" do
    setup :context

    test "a member may post/create_event/upload_file but not manage or moderate", %{
      community: community,
      group: group,
      member: member
    } do
      can = find_group(groups(member, community), group)["viewer_can"]

      assert "post" in can
      assert "create_event" in can
      assert "upload_file" in can
      refute "moderate" in can
      refute "manage_group" in can
      refute "manage_members" in can
    end

    test "an admin gets the full management set", %{
      community: community,
      group: group,
      admin: admin
    } do
      can = find_group(groups(admin, community), group)["viewer_can"]

      assert "moderate" in can
      assert "manage_group" in can
      assert "manage_members" in can
      assert "post" in can
    end

    test "feature toggles gate create_event and upload_file", %{
      community: community,
      member: member
    } do
      # Features are set through their own changeset, never at creation.
      feed_only =
        community
        |> group_fixture()
        |> Kammer.Groups.Group.features_changeset(%{features: [:feed]})
        |> Kammer.Repo.update!()

      group_membership_fixture(feed_only, member)

      can = find_group(groups(member, community), feed_only)["viewer_can"]

      assert "post" in can
      refute "create_event" in can
      refute "upload_file" in can
    end
  end

  describe "community viewer_can" do
    setup :context

    test "an owner may manage the community; a plain member may not", %{
      community: community,
      owner: owner,
      member: member
    } do
      owner_can = find_community(communities(owner), community)["viewer_can"]
      assert "manage_community" in owner_can
      assert "create_group" in owner_can
      assert "view_member_directory" in owner_can

      member_can = find_community(communities(member), community)["viewer_can"]
      refute "manage_community" in member_can
      assert "create_group" in member_can
      assert "view_member_directory" in member_can
    end
  end

  describe "without a relationship" do
    setup :context

    test "the serializer emits an empty capability set rather than guessing", %{
      community: community,
      group: group,
      member: member
    } do
      {:ok, post} = Feed.create_post(member, group, %{"body_markdown" => "x"})
      post = Feed.get_post!(group, post.id)

      # No relationship threaded in — unknown rights read as "no
      # controls", never as a leaked capability.
      assert Serializer.community(community, member)[:viewer_can] == []
      assert Serializer.group(group, member)[:viewer_can] == []
      assert Serializer.post(post, member)[:viewer_can] == []
    end
  end

  defp find_group(list, group), do: Enum.find(list, &(&1["id"] == group.id))
  defp find_community(list, community), do: Enum.find(list, &(&1["id"] == community.id))
end
