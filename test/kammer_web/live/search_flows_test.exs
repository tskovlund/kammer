defmodule KammerWeb.SearchFlowsTest do
  @moduledoc """
  The search page end to end (SPEC §16): members find their content,
  anonymous visitors search only the public face.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Feed

  defp search_context(_context) do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community, visibility: :community)
    member = group_member_fixture(group)

    {:ok, _post} =
      Feed.create_post(member, group, %{"body_markdown" => "Sommerkoncerten er bekræftet"})

    %{community: community, group: group, member: member}
  end

  describe "searching" do
    setup :search_context

    test "a member finds a post and lands on it", %{
      community: community,
      group: group,
      member: member
    } do
      conn = log_in_user(build_conn(), member)
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/search")

      lv |> form("#search-form", %{q: "sommerkoncerten"}) |> render_change()

      html = render(lv)
      assert html =~ "Sommerkoncerten er bekræftet"
      assert html =~ group.name
    end

    test "anonymous visitors don't see community-only content", %{
      conn: conn,
      community: community
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/search")

      lv |> form("#search-form", %{q: "sommerkoncerten"}) |> render_change()

      html = render(lv)
      refute html =~ "Sommerkoncerten er bekræftet"
      assert html =~ "Nothing found"
    end
  end
end
