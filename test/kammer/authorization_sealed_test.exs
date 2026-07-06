defmodule Kammer.AuthorizationSealedTest do
  @moduledoc """
  Dedicated sealed-group rule suite (SPEC §3, §17, ADR 0005).

  The contract: a sealed group grants community admins **no access of any
  kind**; their sole power is whole-group deletion. Sealing must make no
  difference to actual group members. Property-based across the entire
  configuration space.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Kammer.Accounts.User
  alias Kammer.Authorization
  alias Kammer.Groups.Group

  @all_group_actions [
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

  defp sealed_group_generator do
    gen all(
          visibility <- StreamData.member_of(Group.visibilities()),
          join_policy <- StreamData.member_of(Group.join_policies()),
          posting_policy <- StreamData.member_of(Group.posting_policies()),
          comment_policy <- StreamData.member_of(Group.comment_policies()),
          archived <- StreamData.boolean()
        ) do
      %Group{
        id: Ecto.UUID.generate(),
        community_id: Ecto.UUID.generate(),
        name: "Sealed Group",
        slug: "sealed-group",
        visibility: visibility,
        join_policy: join_policy,
        posting_policy: posting_policy,
        comment_policy: comment_policy,
        sealed: true,
        archived_at: if(archived, do: ~U[2026-01-01 00:00:00Z])
      }
    end
  end

  defp actor_for(relationship) do
    %User{
      id: Ecto.UUID.generate(),
      email: "sealed-property@example.com",
      display_name: "Sealed Property Actor",
      instance_operator: relationship.instance_operator?
    }
  end

  property "on sealed groups, community admins are reduced to plain-member rights, except delete_group" do
    check all(
            group <- sealed_group_generator(),
            community_role <- StreamData.member_of([:admin, :owner]),
            action <- StreamData.member_of(@all_group_actions)
          ) do
      admin_relationship = %{
        instance_operator?: false,
        community_role: community_role,
        group_role: nil
      }

      plain_member_relationship = %{
        instance_operator?: false,
        community_role: :member,
        group_role: nil
      }

      admin_allowed =
        Authorization.can?(actor_for(admin_relationship), action, group, admin_relationship)

      plain_member_allowed =
        Authorization.can?(
          actor_for(plain_member_relationship),
          action,
          group,
          plain_member_relationship
        )

      case action do
        :delete_group ->
          assert admin_allowed, "community #{community_role} must retain whole-group deletion"

        _any_other_action ->
          assert admin_allowed == plain_member_allowed,
                 "sealed group: community #{community_role} decision for #{action} " <>
                   "differed from a plain member's (admin: #{admin_allowed}, " <>
                   "member: #{plain_member_allowed})"
      end
    end
  end

  property "sealing changes nothing for the group's own members" do
    check all(
            group <- sealed_group_generator(),
            group_role <- StreamData.member_of([:member, :admin, :owner]),
            action <- StreamData.member_of(@all_group_actions)
          ) do
      relationship = %{
        instance_operator?: false,
        community_role: :member,
        group_role: group_role
      }

      sealed_group = %Group{group | sealed: true}
      unsealed_group = %Group{group | sealed: false}
      actor = actor_for(relationship)

      assert Authorization.can?(actor, action, sealed_group, relationship) ==
               Authorization.can?(actor, action, unsealed_group, relationship),
             "sealing changed #{action} for a group #{group_role}"
    end
  end

  property "instance operator flag grants nothing extra on sealed groups" do
    check all(
            group <- sealed_group_generator(),
            action <- StreamData.member_of(@all_group_actions)
          ) do
      operator = %{instance_operator?: true, community_role: nil, group_role: nil}
      stranger = %{instance_operator?: false, community_role: nil, group_role: nil}

      assert Authorization.can?(actor_for(operator), action, group, operator) ==
               Authorization.can?(actor_for(stranger), action, group, stranger)
    end
  end

  test "the sealed flag is irreversible: update changeset never casts it" do
    sealed_group = %Group{
      id: Ecto.UUID.generate(),
      community_id: Ecto.UUID.generate(),
      name: "Bandroom",
      slug: "bandroom",
      sealed: true
    }

    changeset = Group.update_changeset(sealed_group, %{"sealed" => false, "name" => "Bandroom"})

    assert Ecto.Changeset.get_field(changeset, :sealed) == true
    refute Map.has_key?(changeset.changes, :sealed)
  end
end
