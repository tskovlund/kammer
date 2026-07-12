defmodule KammerWeb.Api.CustomFieldControllerTest do
  @moduledoc """
  Custom profile-field *definition* management over the API (issue #259,
  part of #187, ADR 0020) — the manager surface ported off the LiveView
  community-settings page: list, add, edit, delete. The answers
  themselves are ProfileController's; this pins the definitions' CRUD,
  the `:manage_community` gate on every verb, and the cross-community
  scoping that keeps one community's field ids out of another's path.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import KammerWeb.ApiHelpers
  import OpenApiSpex.TestAssertions

  alias Kammer.Communities

  setup do
    {community, owner} = community_with_owner_fixture()
    %{community: community, owner: owner}
  end

  describe "manager CRUD" do
    test "a manager lists, adds, sets required, and deletes fields — conformance on each", %{
      community: community,
      owner: owner
    } do
      # Empty to start (conformance on the list shape).
      assert owner
             |> api_conn()
             |> get(~p"/api/v1/communities/#{community.slug}/custom-fields")
             |> tap(&assert_operation_response(&1, "custom_fields_index"))
             |> json_response(200)
             |> Map.fetch!("data") == []

      # Add one.
      created =
        owner
        |> api_conn()
        |> post(~p"/api/v1/communities/#{community.slug}/custom-fields", %{
          label: "Instrument",
          field_type: "text",
          visibility: "members"
        })
        |> tap(&assert_operation_response(&1, "custom_fields_create"))
        |> json_response(201)

      field_id = created["data"]["id"]
      assert created["data"]["label"] == "Instrument"
      refute created["data"]["required"]

      # It now lists.
      assert owner
             |> api_conn()
             |> get(~p"/api/v1/communities/#{community.slug}/custom-fields")
             |> json_response(200)
             |> Map.fetch!("data")
             |> Enum.map(& &1["id"]) == [field_id]

      # Set it required (the PUT carries the value, not a toggle command).
      assert owner
             |> api_conn()
             |> put(~p"/api/v1/communities/#{community.slug}/custom-fields/#{field_id}", %{
               required: true
             })
             |> tap(&assert_operation_response(&1, "custom_fields_update"))
             |> json_response(200)
             |> get_in(["data", "required"])

      # Delete it.
      owner
      |> api_conn()
      |> delete(~p"/api/v1/communities/#{community.slug}/custom-fields/#{field_id}")
      |> tap(&assert_operation_response(&1, "custom_fields_delete"))
      |> json_response(200)

      assert owner
             |> api_conn()
             |> get(~p"/api/v1/communities/#{community.slug}/custom-fields")
             |> json_response(200)
             |> Map.fetch!("data") == []
    end

    test "single_select without options is rejected 422 naming options", %{
      community: community,
      owner: owner
    } do
      %{"error" => %{"code" => "invalid_params", "details" => details}} =
        owner
        |> api_conn()
        |> post(~p"/api/v1/communities/#{community.slug}/custom-fields", %{
          label: "Section",
          field_type: "single_select",
          options: []
        })
        |> json_response(422)

      # Pin the failure to `options` — not just any 422 — so the test
      # can't pass on an unrelated validation error.
      assert details["options"]
    end

    test "update edits label, visibility, and required — but never type or options", %{
      community: community,
      owner: owner
    } do
      {:ok, field} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Instrument",
          "field_type" => "text",
          "visibility" => "members"
        })

      # The editable set is label/visibility/required; field_type and
      # options are frozen once a field exists (changing them would orphan
      # members' answers). The controller's `@update_fields` whitelist is
      # the sole guard — the context changeset would happily cast the rest
      # — so pin both halves: what changes, and what can't.
      data =
        owner
        |> api_conn()
        |> put(~p"/api/v1/communities/#{community.slug}/custom-fields/#{field.id}", %{
          label: "Main instrument",
          visibility: "admins",
          required: true,
          field_type: "single_select",
          options: ["Smuggled"]
        })
        |> json_response(200)
        |> Map.fetch!("data")

      # Editable — applied.
      assert data["label"] == "Main instrument"
      assert data["visibility"] == "admins"
      assert data["required"]
      # Frozen — the smuggled type/options are ignored.
      assert data["field_type"] == "text"
      assert data["options"] == []
    end
  end

  describe "authorization" do
    setup %{community: community, owner: owner} do
      {:ok, field} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Instrument",
          "field_type" => "text"
        })

      %{field: field}
    end

    test "an ordinary member is refused every management verb (403)", %{
      community: community,
      field: field
    } do
      member = member_fixture(community)

      # The list is manager-only even though the definitions aren't a
      # secret — an honest 403, not a hidden 404.
      member
      |> api_conn()
      |> get(~p"/api/v1/communities/#{community.slug}/custom-fields")
      |> json_response(403)

      member
      |> api_conn()
      |> post(~p"/api/v1/communities/#{community.slug}/custom-fields", %{
        label: "Nej",
        field_type: "text"
      })
      |> json_response(403)

      member
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/custom-fields/#{field.id}", %{
        required: true
      })
      |> json_response(403)

      member
      |> api_conn()
      |> delete(~p"/api/v1/communities/#{community.slug}/custom-fields/#{field.id}")
      |> json_response(403)
    end

    test "a field from another community 404s through this community's path", %{
      community: community,
      owner: owner
    } do
      {other_community, other_owner} = community_with_owner_fixture()

      {:ok, other_field} =
        Communities.create_custom_field(other_owner, other_community, %{
          "label" => "Elsewhere",
          "field_type" => "text"
        })

      # `owner` manages `community`, but `other_field` lives elsewhere —
      # scoped out to a clean 404, never reachable by pairing this
      # community's slug with a foreign field id.
      owner
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/custom-fields/#{other_field.id}", %{
        required: true
      })
      |> json_response(404)

      owner
      |> api_conn()
      |> delete(~p"/api/v1/communities/#{community.slug}/custom-fields/#{other_field.id}")
      |> json_response(404)
    end

    test "a malformed (non-UUID) field id is a clean 404, not a 500", %{
      community: community,
      owner: owner
    } do
      # `:id` has no UUID constraint in the router, so `not-a-uuid` reaches
      # the controller; `get_custom_field/2` casts before it queries, so
      # the scoped fetch answers nil → 404 rather than raising a
      # `Ecto.Query.CastError` (500) on attacker-controlled path input.
      owner
      |> api_conn()
      |> put(~p"/api/v1/communities/#{community.slug}/custom-fields/not-a-uuid", %{required: true})
      |> json_response(404)

      owner
      |> api_conn()
      |> delete(~p"/api/v1/communities/#{community.slug}/custom-fields/not-a-uuid")
      |> json_response(404)
    end
  end
end
