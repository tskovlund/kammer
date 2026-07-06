defmodule Kammer.AuthorizationFilesTest do
  @moduledoc """
  Dedicated suite for the file-visibility invariant (SPEC §7, §17,
  ADR 0009), property-based:

  **File/folder visibility can never exceed the owning scope's visibility
  preset** — and folder preset overrides can only restrict access, never
  widen it.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Kammer.Accounts.User
  alias Kammer.Authorization
  alias Kammer.Communities.Community
  alias Kammer.Files.Folder
  alias Kammer.Groups.Group

  defp group_scope_generator do
    gen all(
          visibility <- StreamData.member_of(Group.visibilities()),
          sealed <- StreamData.boolean(),
          archived <- StreamData.boolean()
        ) do
      %Group{
        id: Ecto.UUID.generate(),
        community_id: Ecto.UUID.generate(),
        name: "Scope Group",
        slug: "scope-group",
        visibility: visibility,
        sealed: sealed,
        archived_at: if(archived, do: ~U[2026-01-01 00:00:00Z])
      }
    end
  end

  defp relationship_generator do
    gen all(
          instance_operator? <- StreamData.boolean(),
          community_role <- StreamData.member_of([nil, :member, :admin, :owner]),
          group_role <- StreamData.member_of([nil, :member, :admin, :owner])
        ) do
      community_role =
        if group_role != nil and community_role == nil, do: :member, else: community_role

      %{
        instance_operator?: instance_operator?,
        community_role: community_role,
        group_role: group_role
      }
    end
  end

  defp folder_chain_generator do
    override = StreamData.member_of([:inherit, :admins_only])

    StreamData.list_of(
      StreamData.tuple({override, override}),
      max_length: 4
    )
    |> StreamData.map(fn overrides ->
      Enum.map(overrides, fn {read_override, write_override} ->
        %Folder{
          id: Ecto.UUID.generate(),
          name: "generated",
          read_override: read_override,
          write_override: write_override
        }
      end)
    end)
  end

  defp actor_for(relationship) do
    %User{
      id: Ecto.UUID.generate(),
      email: "files-property@example.com",
      display_name: "Files Property Actor",
      instance_operator: relationship.instance_operator?
    }
  end

  property "THE INVARIANT: file read access never exceeds scope visibility" do
    check all(
            group <- group_scope_generator(),
            relationship <- relationship_generator(),
            folder_chain <- folder_chain_generator()
          ) do
      actor = actor_for(relationship)

      if Authorization.can_read_folder?(actor, group, folder_chain, relationship) do
        assert Authorization.can?(actor, :view_group, group, relationship),
               "actor could read files in a #{group.visibility} group they cannot view"
      end
    end
  end

  property "overrides only restrict: adding admins_only never grants access" do
    check all(
            group <- group_scope_generator(),
            relationship <- relationship_generator(),
            folder_chain <- folder_chain_generator()
          ) do
      actor = actor_for(relationship)

      restricted_chain =
        folder_chain ++
          [
            %Folder{
              id: Ecto.UUID.generate(),
              name: "locked",
              read_override: :admins_only,
              write_override: :admins_only
            }
          ]

      read_before = Authorization.can_read_folder?(actor, group, folder_chain, relationship)
      read_after = Authorization.can_read_folder?(actor, group, restricted_chain, relationship)
      write_before = Authorization.can_write_folder?(actor, group, folder_chain, relationship)
      write_after = Authorization.can_write_folder?(actor, group, restricted_chain, relationship)

      refute not read_before and read_after, "restriction widened read access"
      refute not write_before and write_after, "restriction widened write access"
    end
  end

  property "admins_only anywhere in the chain locks out plain members" do
    check all(
            group <- group_scope_generator(),
            folder_chain <- folder_chain_generator()
          ) do
      plain_member = %{instance_operator?: false, community_role: :member, group_role: :member}
      actor = actor_for(plain_member)

      restricted? = Enum.any?(folder_chain, fn folder -> folder.read_override == :admins_only end)

      if restricted? do
        refute Authorization.can_read_folder?(actor, group, folder_chain, plain_member)
      end
    end
  end

  property "writing requires membership and a live (unarchived) group" do
    check all(
            group <- group_scope_generator(),
            relationship <- relationship_generator(),
            folder_chain <- folder_chain_generator()
          ) do
      actor = actor_for(relationship)

      if Authorization.can_write_folder?(actor, group, folder_chain, relationship) do
        assert relationship.group_role != nil or
                 (relationship.community_role in [:owner, :admin] and not group.sealed)

        refute Group.archived?(group), "wrote into an archived group"
      end
    end
  end

  property "sealed groups: community admins get no file access beyond plain members" do
    check all(
            group <- group_scope_generator(),
            folder_chain <- folder_chain_generator()
          ) do
      sealed_group = %Group{group | sealed: true}

      admin = %{instance_operator?: false, community_role: :admin, group_role: nil}
      plain_member = %{instance_operator?: false, community_role: :member, group_role: nil}

      assert Authorization.can_read_folder?(actor_for(admin), sealed_group, folder_chain, admin) ==
               Authorization.can_read_folder?(
                 actor_for(plain_member),
                 sealed_group,
                 folder_chain,
                 plain_member
               )
    end
  end

  describe "community scope" do
    test "community files require community membership; anonymous never reads" do
      community = %Community{id: Ecto.UUID.generate(), name: "TK", slug: "tk"}
      outsider = %{instance_operator?: false, community_role: nil, group_role: nil}
      member = %{instance_operator?: false, community_role: :member, group_role: nil}

      refute Authorization.can_read_folder?(actor_for(outsider), community, [], outsider)
      assert Authorization.can_read_folder?(actor_for(member), community, [], member)

      anonymous = %{instance_operator?: false, community_role: nil, group_role: nil}
      refute Authorization.can_read_folder?(nil, community, [], anonymous)
      refute Authorization.can_write_folder?(nil, community, [], anonymous)
    end
  end
end
