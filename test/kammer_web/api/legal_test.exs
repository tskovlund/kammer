defmodule KammerWeb.Api.LegalTest do
  @moduledoc """
  Legal pages over the API (issues #185/#259, SPEC §13): anyone reads
  the privacy policy or imprint — the built-in template until an
  operator publishes their own text, then that. Publishing is the
  operator-only PUT twin of `LegalLive.Edit`; an unknown key is a
  neutral 404 to both verbs.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures, only: [instance_operator_fixture: 0]
  import KammerWeb.ApiHelpers
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

  describe "editing (issue #259)" do
    test "an operator publishes; a non-operator is refused and the template stays" do
      operator = instance_operator_fixture()
      member = user_fixture()

      member
      |> api_conn()
      |> put(~p"/api/v1/legal/privacy", %{content_markdown: "# Nej"})
      |> json_response(403)

      refute Legal.published?("privacy")

      body =
        operator
        |> api_conn()
        |> put(~p"/api/v1/legal/privacy", %{content_markdown: "# Vores politik"})
        |> tap(&assert_operation_response(&1, "legal_update"))
        |> json_response(200)

      # The answer is the same shape the public read serves — the fresh
      # text, its rendered HTML, and the flipped published flag.
      assert body["data"]["published"] == true
      assert body["data"]["content_markdown"] == "# Vores politik"
      assert body["data"]["content_html"] =~ "Vores politik"
      assert Legal.published?("privacy")
    end

    test "an unknown key answers 404, and empty content 422 naming content_markdown" do
      operator = instance_operator_fixture()

      operator
      |> api_conn()
      |> put(~p"/api/v1/legal/nonsense", %{content_markdown: "# Hvad"})
      |> json_response(404)

      # An empty body must not silently blank a page — the detail lands
      # on `content_markdown`, the field a client form maps to copy.
      %{"error" => %{"code" => "invalid_params", "details" => details}} =
        operator
        |> api_conn()
        |> put(~p"/api/v1/legal/imprint", %{content_markdown: ""})
        |> json_response(422)

      assert details["content_markdown"]
    end
  end

  defp public_conn, do: put_req_header(build_conn(), "accept", "application/json")
end
