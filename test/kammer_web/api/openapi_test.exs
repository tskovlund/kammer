defmodule KammerWeb.Api.OpenapiTest do
  @moduledoc """
  The contract drift guard (issue #30): every API route in the router
  must appear in the OpenAPI document with its method, and the
  document must not describe routes that don't exist. If this fails,
  the contract fell behind the code (or vice versa) — fix the spec,
  never delete the test.
  """

  use KammerWeb.ConnCase, async: true

  test "the OpenAPI document and the router describe the same API" do
    spec = KammerWeb.ApiSpec.spec()

    router_operations =
      for route <- KammerWeb.Router.__routes__(),
          String.starts_with?(route.path, "/api/"),
          do: {route.verb, openapi_path(route.path)}

    spec_operations =
      for {path, path_item} <- spec.paths,
          {verb, operation} <- Map.from_struct(path_item),
          match?(%OpenApiSpex.Operation{}, operation),
          do: {verb, path}

    assert Enum.sort(router_operations) == Enum.sort(spec_operations)
  end

  test "GET /api/v1/openapi.json serves a valid document", %{conn: conn} do
    body =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/v1/openapi.json")
      |> json_response(200)

    assert body["openapi"]
    assert body["info"]["title"] == "Kammer API"
    assert body["components"]["schemas"]["Post"]
    assert body["components"]["schemas"]["Error"]
  end

  defp openapi_path(router_path) do
    router_path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> param -> "{#{param}}"
      segment -> segment
    end)
  end
end
