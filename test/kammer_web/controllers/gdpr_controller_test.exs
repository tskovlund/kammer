defmodule KammerWeb.GdprControllerTest do
  @moduledoc """
  The self-serve data export route (SPEC §12): a personal-data
  disclosure surface, so the tests are the gate — the signed-in user
  gets their own zip, anonymous callers are sent to log in.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures

  alias Kammer.Feed

  describe "GET /users/settings/export" do
    test "an authenticated user downloads a zip of their own data", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      member = group_member_fixture(group)
      {:ok, _post} = Feed.create_post(member, group, %{"body_markdown" => "Mine egne ord"})

      conn = conn |> log_in_user(member) |> get(~p"/users/settings/export")

      assert response_content_type(conn, :zip)

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ ".zip"

      {:ok, entries} = :zip.unzip(response(conn, 200), [:memory])

      {_name, json} =
        Enum.find(entries, fn {name, _content} -> to_string(name) == "data.json" end)

      data = Jason.decode!(json)
      assert data["profile"]["email"] == member.email
      assert [%{"body_markdown" => "Mine egne ord"}] = data["posts"]
    end

    test "anonymous requests are redirected to log in", %{conn: conn} do
      conn = get(conn, ~p"/users/settings/export")

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
