defmodule Kammer.CommunitiesCustomFieldsTest do
  @moduledoc """
  Community-defined custom profile fields (SPEC §4) — the roster:
  CRUD authorization, per-member answers, required-field hard-block/
  nag semantics, and directory visibility.
  """

  use Kammer.DataCase, async: true

  import Kammer.CommunitiesFixtures

  alias Kammer.Communities

  describe "create_custom_field/3" do
    test "requires manage_community" do
      {community, owner} = community_with_owner_fixture()
      plain_member = member_fixture(community)

      assert {:error, :unauthorized} =
               Communities.create_custom_field(plain_member, community, %{
                 "label" => "Instrument",
                 "field_type" => "text"
               })

      assert {:ok, field} =
               Communities.create_custom_field(owner, community, %{
                 "label" => "Instrument",
                 "field_type" => "text"
               })

      assert field.label == "Instrument"
      assert field.field_type == :text
      assert field.visibility == :members
    end

    test "single_select requires at least one option" do
      {community, owner} = community_with_owner_fixture()

      assert {:error, changeset} =
               Communities.create_custom_field(owner, community, %{
                 "label" => "Section",
                 "field_type" => "single_select",
                 "options" => []
               })

      assert "must list at least one option" in errors_on(changeset).options
    end
  end

  describe "delete_custom_field/3" do
    test "requires manage_community and removes answers with it" do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)

      {:ok, field} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Instrument",
          "field_type" => "text"
        })

      :ok = Communities.put_custom_field_values(member, community, %{field.id => "Tuba"})
      assert Communities.get_custom_field_values(community, member) == %{field.id => "Tuba"}

      plain_member = member_fixture(community)

      assert {:error, :unauthorized} =
               Communities.delete_custom_field(plain_member, community, field)

      assert {:ok, _deleted} = Communities.delete_custom_field(owner, community, field)
      assert Communities.list_custom_fields(community) == []
      assert Communities.get_custom_field_values(community, member) == %{}
    end
  end

  describe "put_custom_field_values/3" do
    test "a blank value clears an existing answer" do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)

      {:ok, field} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Instrument",
          "field_type" => "text"
        })

      :ok = Communities.put_custom_field_values(member, community, %{field.id => "Tuba"})
      assert Communities.get_custom_field_values(community, member) == %{field.id => "Tuba"}

      :ok = Communities.put_custom_field_values(member, community, %{field.id => "  "})
      assert Communities.get_custom_field_values(community, member) == %{}
    end

    test "values for fields outside the community are ignored" do
      {community, _owner} = community_with_owner_fixture()
      {other_community, other_owner} = community_with_owner_fixture()
      member = member_fixture(community)

      {:ok, foreign_field} =
        Communities.create_custom_field(other_owner, other_community, %{
          "label" => "Foreign",
          "field_type" => "text"
        })

      :ok = Communities.put_custom_field_values(member, community, %{foreign_field.id => "Nope"})
      assert Communities.get_custom_field_values(community, member) == %{}
    end
  end

  describe "missing_required_custom_fields/2" do
    test "hard-blocks on required fields with no answer, clears once answered" do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)

      {:ok, required_field} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Instrument",
          "field_type" => "text",
          "required" => true
        })

      {:ok, _optional_field} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Fun fact",
          "field_type" => "text"
        })

      assert Communities.missing_required_custom_fields(community, member) == [required_field]

      :ok = Communities.put_custom_field_values(member, community, %{required_field.id => "Tuba"})
      assert Communities.missing_required_custom_fields(community, member) == []
    end

    test "making an existing field required nags already-answered members correctly" do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)

      {:ok, field} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Instrument",
          "field_type" => "text"
        })

      # Joined while the field was optional and never answered it.
      assert Communities.missing_required_custom_fields(community, member) == []

      {:ok, field} =
        Communities.update_custom_field(owner, community, field, %{"required" => true})

      assert Communities.missing_required_custom_fields(community, member) == [field]
    end

    test "update_custom_field/4 requires manage_community" do
      {community, owner} = community_with_owner_fixture()
      plain_member = member_fixture(community)

      {:ok, field} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Instrument",
          "field_type" => "text"
        })

      assert {:error, :unauthorized} =
               Communities.update_custom_field(plain_member, community, field, %{
                 "required" => true
               })
    end
  end

  describe "visible_custom_field_values/3 and list_visible_custom_fields/2" do
    test "members-visibility fields show to any member, admins-only fields don't" do
      {community, owner} = community_with_owner_fixture()
      target = member_fixture(community)

      {:ok, section} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Section",
          "field_type" => "text",
          "visibility" => "members"
        })

      {:ok, dietary} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Dietary needs",
          "field_type" => "text",
          "visibility" => "admins"
        })

      :ok =
        Communities.put_custom_field_values(target, community, %{
          section.id => "Brass",
          dietary.id => "Vegan"
        })

      assert Communities.visible_custom_field_values(community, target, :member) ==
               [{section, "Brass"}]

      assert Communities.visible_custom_field_values(community, target, :admin) ==
               [{section, "Brass"}, {dietary, "Vegan"}]

      assert Communities.visible_custom_field_values(community, target, nil) == []

      assert Communities.list_visible_custom_fields(community, :member) == [section]
      assert Communities.list_visible_custom_fields(community, :admin) == [section, dietary]
    end
  end

  describe "custom_field_values_by_user/2" do
    test "batches answers for many members in one call" do
      {community, owner} = community_with_owner_fixture()
      alice = member_fixture(community)
      bob = member_fixture(community)

      {:ok, field} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Instrument",
          "field_type" => "text"
        })

      :ok = Communities.put_custom_field_values(alice, community, %{field.id => "Tuba"})
      :ok = Communities.put_custom_field_values(bob, community, %{field.id => "Oboe"})

      values = Communities.custom_field_values_by_user(community, [alice, bob])

      assert values[alice.id] == %{field.id => "Tuba"}
      assert values[bob.id] == %{field.id => "Oboe"}
    end
  end
end
