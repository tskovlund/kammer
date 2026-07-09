defmodule Kammer.AuthorizationTest do
  @moduledoc """
  Dedicated test suite for the central authorization module (SPEC §17).

  The pure decision core `Kammer.Authorization.can?/4` is exercised
  property-based over the whole space of group configurations and actor
  relationships; the sealed-group rules (ADR 0005) get their own suite
  below.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Kammer.Accounts.User
  alias Kammer.Authorization
  alias Kammer.Communities.Community
  alias Kammer.Groups.Group

  @group_actions [
    :view_group,
    :join_group,
    :request_to_join_group,
    :manage_group,
    :archive_group,
    :unarchive_group,
    :delete_group,
    :create_group_invite,
    :approve_group_members,
    :post_in_group,
    :comment_in_group,
    :post_as_group,
    :moderate_group
  ]

  @content_actions [:post_in_group, :comment_in_group, :post_as_group]

  # The membership/admin actions `Kammer.Authorization` also gates on
  # `not Group.archived?/1` — read-only means no new members and no new
  # invites, not just no new content (SPEC §3).
  @membership_actions [
    :join_group,
    :request_to_join_group,
    :create_group_invite,
    :approve_group_members
  ]

  defp group_generator do
    gen all(
          visibility <- StreamData.member_of(Group.visibilities()),
          join_policy <- StreamData.member_of(Group.join_policies()),
          posting_policy <- StreamData.member_of(Group.posting_policies()),
          comment_policy <- StreamData.member_of(Group.comment_policies()),
          sealed <- StreamData.boolean(),
          archived <- StreamData.boolean()
        ) do
      %Group{
        id: Ecto.UUID.generate(),
        community_id: Ecto.UUID.generate(),
        name: "Generated Group",
        slug: "generated-group",
        visibility: visibility,
        join_policy: join_policy,
        posting_policy: posting_policy,
        comment_policy: comment_policy,
        approval_queue: false,
        sealed: sealed,
        archived_at: if(archived, do: ~U[2026-01-01 00:00:00Z])
      }
    end
  end

  defp relationship_generator do
    gen all(
          instance_operator? <- StreamData.boolean(),
          community_role <- StreamData.member_of([nil, :member, :admin, :owner]),
          group_role <-
            StreamData.member_of([nil, :member, :admin, :owner])
        ) do
      # Invariant maintained by the contexts: group members are always
      # community members.
      community_role =
        if group_role != nil and community_role == nil, do: :member, else: community_role

      %{
        instance_operator?: instance_operator?,
        community_role: community_role,
        group_role: group_role
      }
    end
  end

  defp actor_for(relationship) do
    %User{
      id: Ecto.UUID.generate(),
      email: "property@example.com",
      display_name: "Property Actor",
      instance_operator: relationship.instance_operator?
    }
  end

  @anonymous_relationship %{instance_operator?: false, community_role: nil, group_role: nil}

  describe "anonymous actors" do
    property "may only ever view public groups — nothing else, on any configuration" do
      check all(group <- group_generator(), action <- StreamData.member_of(@group_actions)) do
        allowed = Authorization.can?(nil, action, group, @anonymous_relationship)

        case action do
          :view_group ->
            assert allowed == group.visibility in [:public_link, :public_listed]

          _other_action ->
            refute allowed
        end
      end
    end
  end

  describe "archived groups are read-only (SPEC §3)" do
    property "no actor can post, comment, or post-as-group in an archived group" do
      check all(
              group <- group_generator(),
              relationship <- relationship_generator(),
              action <- StreamData.member_of(@content_actions)
            ) do
        archived_group = %Group{group | archived_at: ~U[2026-01-01 00:00:00Z]}
        actor = actor_for(relationship)

        refute Authorization.can?(actor, action, archived_group, relationship)
      end
    end

    property "no actor can join, request to join, invite into, or approve members for an archived group" do
      check all(
              group <- group_generator(),
              relationship <- relationship_generator(),
              action <- StreamData.member_of(@membership_actions)
            ) do
        archived_group = %Group{group | archived_at: ~U[2026-01-01 00:00:00Z]}
        actor = actor_for(relationship)

        refute Authorization.can?(actor, action, archived_group, relationship)
      end
    end

    property "archiving never removes view access" do
      check all(group <- group_generator(), relationship <- relationship_generator()) do
        actor = actor_for(relationship)
        live_group = %Group{group | archived_at: nil}
        archived_group = %Group{group | archived_at: ~U[2026-01-01 00:00:00Z]}

        if Authorization.can?(actor, :view_group, live_group, relationship) do
          assert Authorization.can?(actor, :view_group, archived_group, relationship)
        end
      end
    end
  end

  describe "instance operators have no content privileges (SPEC §3)" do
    property "toggling the operator flag never changes any group decision" do
      check all(
              group <- group_generator(),
              relationship <- relationship_generator(),
              action <- StreamData.member_of(@group_actions)
            ) do
        as_operator = %{relationship | instance_operator?: true}
        as_plain_user = %{relationship | instance_operator?: false}

        assert Authorization.can?(actor_for(as_operator), action, group, as_operator) ==
                 Authorization.can?(actor_for(as_plain_user), action, group, as_plain_user)
      end
    end
  end

  describe "instance_operator?/1" do
    test "true only for a user with the flag set, regardless of actor shape" do
      operator = %User{id: Ecto.UUID.generate(), instance_operator: true}
      plain_user = %User{id: Ecto.UUID.generate(), instance_operator: false}

      assert Authorization.instance_operator?(operator)
      assert Authorization.instance_operator?(%Kammer.Accounts.Scope{user: operator})
      refute Authorization.instance_operator?(plain_user)
      refute Authorization.instance_operator?(%Kammer.Accounts.Scope{user: plain_user})
      refute Authorization.instance_operator?(%Kammer.Accounts.Scope{user: nil})
      refute Authorization.instance_operator?(nil)
    end
  end

  describe "role monotonicity" do
    property "a group admin can do everything a plain group member can" do
      check all(group <- group_generator(), action <- StreamData.member_of(@group_actions)) do
        member = %{instance_operator?: false, community_role: :member, group_role: :member}
        admin = %{instance_operator?: false, community_role: :member, group_role: :admin}

        member_allowed = Authorization.can?(actor_for(member), action, group, member)
        admin_allowed = Authorization.can?(actor_for(admin), action, group, admin)

        # join/request actions only apply to non-members; ignore them here.
        unless action in [:join_group, :request_to_join_group] do
          assert admin_allowed or not member_allowed,
                 "member allowed #{action} but admin was not"
        end
      end
    end
  end

  describe "visibility presets (ADR 0004)" do
    test "private groups are invisible to plain community members" do
      group = %Group{sealed: false, visibility: :private, community_id: Ecto.UUID.generate()}

      relationship = %{instance_operator?: false, community_role: :member, group_role: nil}

      refute Authorization.can?(actor_for(relationship), :view_group, group, relationship)
    end

    test "community groups are invisible to signed-in non-members of the community" do
      group = %Group{sealed: false, visibility: :community, community_id: Ecto.UUID.generate()}
      relationship = %{instance_operator?: false, community_role: nil, group_role: nil}

      refute Authorization.can?(actor_for(relationship), :view_group, group, relationship)
    end
  end

  describe "posting and commenting policies" do
    test "admins-only posting blocks plain members but not group admins" do
      group = %Group{sealed: false, posting_policy: :admins_only, comment_policy: :members}
      member = %{instance_operator?: false, community_role: :member, group_role: :member}
      admin = %{instance_operator?: false, community_role: :member, group_role: :admin}

      refute Authorization.can?(actor_for(member), :post_in_group, group, member)
      assert Authorization.can?(actor_for(admin), :post_in_group, group, admin)
    end

    test "comments off blocks everyone including admins" do
      group = %Group{sealed: false, comment_policy: :off}
      admin = %{instance_operator?: false, community_role: :member, group_role: :owner}

      refute Authorization.can?(actor_for(admin), :comment_in_group, group, admin)
    end

    test "post_as_group requires admin powers" do
      group = %Group{sealed: false, posting_policy: :all_members}
      member = %{instance_operator?: false, community_role: :member, group_role: :member}
      admin = %{instance_operator?: false, community_role: :member, group_role: :admin}

      refute Authorization.can?(actor_for(member), :post_as_group, group, member)
      assert Authorization.can?(actor_for(admin), :post_as_group, group, admin)
    end
  end

  describe "community actions" do
    test "only members see the community and its directory" do
      community = %Community{id: Ecto.UUID.generate(), name: "TK", slug: "tk"}
      outsider = %{instance_operator?: false, community_role: nil, group_role: nil}
      member = %{instance_operator?: false, community_role: :member, group_role: nil}

      refute Authorization.can?(actor_for(outsider), :view_community, community, outsider)
      assert Authorization.can?(actor_for(member), :view_community, community, member)

      refute Authorization.can?(
               actor_for(outsider),
               :view_member_directory,
               community,
               outsider
             )
    end

    test "management requires admin, deletion requires owner" do
      community = %Community{id: Ecto.UUID.generate(), name: "TK", slug: "tk"}
      member = %{instance_operator?: false, community_role: :member, group_role: nil}
      admin = %{instance_operator?: false, community_role: :admin, group_role: nil}
      owner = %{instance_operator?: false, community_role: :owner, group_role: nil}

      refute Authorization.can?(actor_for(member), :manage_community, community, member)
      assert Authorization.can?(actor_for(admin), :manage_community, community, admin)
      refute Authorization.can?(actor_for(admin), :delete_community, community, admin)
      assert Authorization.can?(actor_for(owner), :delete_community, community, owner)
    end
  end

  describe "can_manage_own_resource?/4 (creator-or-moderator: events, polls, assignments, decisions)" do
    property "the creator can always manage their own resource, on any relationship" do
      check all(group <- group_generator(), relationship <- relationship_generator()) do
        actor = actor_for(relationship)
        assert Authorization.can_manage_own_resource?(actor, actor.id, group, relationship)
      end
    end

    property "a group moderator can always manage any resource in their group" do
      check all(group <- group_generator()) do
        moderator_relationship = %{
          instance_operator?: false,
          community_role: :member,
          group_role: :admin
        }

        moderator = actor_for(moderator_relationship)
        someone_elses_resource = Ecto.UUID.generate()

        assert Authorization.can_manage_own_resource?(
                 moderator,
                 someone_elses_resource,
                 group,
                 moderator_relationship
               )
      end
    end

    property "a plain member who isn't the creator can never manage the resource" do
      check all(group <- group_generator()) do
        member_relationship = %{
          instance_operator?: false,
          community_role: :member,
          group_role: :member
        }

        member = actor_for(member_relationship)
        someone_elses_resource = Ecto.UUID.generate()

        refute Authorization.can_manage_own_resource?(
                 member,
                 someone_elses_resource,
                 group,
                 member_relationship
               )
      end
    end

    test "anonymous actors can never manage a resource, even one with no creator" do
      group = %Group{sealed: false}
      refute Authorization.can_manage_own_resource?(nil, nil, group, @anonymous_relationship)
    end
  end
end
