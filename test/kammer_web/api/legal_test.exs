defmodule KammerWeb.Api.LegalTest do
  @moduledoc """
  Public legal pages over the API (issue #185, SPEC §13): anyone reads
  the privacy policy or imprint — the built-in template until an
  operator publishes their own text, then that. An unknown key is a
  neutral 404.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import OpenApiSpex.TestAssertions

  alias Kammer.Legal
  alias Kammer.Repo

  test "an unpublished page returns the built-in template" do
    body = public_conn() |> get(~p"/api/v1/legal/privacy") |> json_response(200)

    assert body["data"]["key"] == "privacy"
    assert body["data"]["published"] == false
    assert body["data"]["content_markdown"] =~ "template"
    assert body["data"]["content_html"] =~ "<"
  end

  test "a published page returns the operator's text and validates against the spec" do
    operator = user_fixture() |> Ecto.Changeset.change(instance_operator: true) |> Repo.update!()
    {:ok, _page} = Legal.upsert_page(operator, "imprint", %{"content_markdown" => "# Run by us"})

    body =
      public_conn()
      |> get(~p"/api/v1/legal/imprint")
      |> tap(&assert_operation_response(&1, "legal_show"))
      |> json_response(200)

    assert body["data"]["published"] == true
    assert body["data"]["content_markdown"] == "# Run by us"
    assert body["data"]["content_html"] =~ "Run by us"
  end

  test "an unknown key is a neutral 404" do
    assert %{"error" => %{"code" => "not_found"}} =
             public_conn() |> get(~p"/api/v1/legal/nonsense") |> json_response(404)
  end

  defp public_conn, do: put_req_header(build_conn(), "accept", "application/json")
end
