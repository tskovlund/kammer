defmodule KammerWeb.CommunityFlowsTest do
  @moduledoc """
  LiveView tests for the critical community/group flows (SPEC §17):
  community creation, group creation, joining, invite redemption, and the
  visibility rules as seen through the UI.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Communities
  alias Kammer.Groups
  alias Kammer.Invitations

  describe "instance home" do
    test "visitors see the landing page with listed communities", %{conn: conn} do
      community_fixture(%{name: "Open Community", listed_on_instance: true})
      community_fixture(%{name: "Hidden Community"})

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Open Community"
      refute html =~ "Hidden Community"
    end

    test "signed-in members see their communities", %{conn: conn} do
      {community, owner} = community_with_owner_fixture(%{name: "My Band"})

      {:ok, _lv, html} =
        conn |> log_in_user(owner) |> live(~p"/")

      assert html =~ "My Band"
      assert html =~ community.slug
    end
  end

  describe "community creation" do
    test "operators create communities through the form", %{conn: conn} do
      operator = instance_operator_fixture()

      {:ok, lv, _html} = conn |> log_in_user(operator) |> live(~p"/communities/new")

      {:ok, _lv, html} =
        lv
        |> form("#community_form", %{
          "community" => %{"name" => "Sample Club", "slug" => "sample-club"}
        })
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Sample Club"
    end

    test "plain users are redirected under operators_only policy", %{conn: conn} do
      plain_user = user_fixture()

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> log_in_user(plain_user) |> live(~p"/communities/new")
    end
  end

  describe "group creation and join flows" do
    setup %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      member = member_fixture(community)
      %{conn: log_in_user(conn, member), community: community, member: member}
    end

    test "member creates a group via the form", %{conn: conn, community: community} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/groups/new")

      {:ok, _lv, html} =
        lv
        |> form("#group_form", %{
          "group" => %{
            "name" => "Brass Section",
            "slug" => "brass-section",
            "visibility" => "community"
          }
        })
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Brass Section"
    end

    test "member joins an open group from the group page",
         %{conn: conn, community: community, member: member} do
      group = group_fixture(community, join_policy: :open)
      group_member_fixture(group, :owner)

      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      lv |> element("button", "Join group") |> render_click()

      assert Groups.get_membership(group, member)
    end

    test "request-approval group shows request button and records the request",
         %{conn: conn, community: community, member: member} do
      group = group_fixture(community, join_policy: :request_approval)

      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      lv |> element("button", "Request to join") |> render_click()

      assert Groups.pending_join_request?(member, group)
    end

    test "private group is not reachable for a plain member",
         %{conn: conn, community: community} do
      group = group_fixture(community, visibility: :private)

      assert {:error, {:live_redirect, %{to: destination}}} =
               live(conn, ~p"/c/#{community.slug}/g/#{group.slug}")

      assert destination == "/c/#{community.slug}"
    end
  end

  describe "groups directory" do
    test "lists visible groups and hides private ones", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      member = member_fixture(community)
      group_fixture(community, name: "Visible Group", visibility: :community)
      group_fixture(community, name: "Secret Group", visibility: :private)

      {:ok, _lv, html} =
        conn |> log_in_user(member) |> live(~p"/c/#{community.slug}/groups")

      assert html =~ "Visible Group"
      refute html =~ "Secret Group"
    end
  end

  describe "invite redemption" do
    test "signed-in user accepts a group invite from the invite page", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, join_policy: :invite_only, visibility: :private)
      group_owner = group_member_fixture(group, :owner)
      {:ok, invite} = Invitations.create_group_invite(group_owner, group)

      newcomer = user_fixture()
      conn = log_in_user(conn, newcomer)

      {:ok, lv, html} = live(conn, ~p"/invite/#{invite.token}")
      assert html =~ group.name

      lv |> element("button", "Accept invitation") |> render_click()

      assert Groups.get_membership(group, newcomer)
    end

    test "signed-out user is routed through sign-in and lands back on acceptance",
         %{conn: conn} do
      {community, owner} = community_with_owner_fixture()
      {:ok, invite} = Invitations.create_community_invite(owner, community)

      # The accept endpoint stores the return path and redirects to log-in.
      conn = get(conn, ~p"/invite/#{invite.token}/accept")
      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :user_return_to) == "/invite/#{invite.token}/accept"

      # After signing in, the user returns and the invite is redeemed.
      newcomer = user_fixture()
      conn = build_conn() |> log_in_user(newcomer) |> get(~p"/invite/#{invite.token}/accept")
      assert redirected_to(conn) == "/c/#{community.slug}"
      assert Kammer.Communities.get_membership(community, newcomer)
    end

    test "invalid invite shows the invalid state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/invite/not-a-real-token")
      assert html =~ "no longer valid"
    end

    test "a required custom field hard-blocks at join, from the in-place accept button",
         %{conn: conn} do
      {community, owner} = community_with_owner_fixture()

      {:ok, field} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Instrument",
          "field_type" => "text",
          "required" => true
        })

      {:ok, invite} = Invitations.create_community_invite(owner, community)
      newcomer = user_fixture()
      conn = log_in_user(conn, newcomer)

      {:ok, lv, _html} = live(conn, ~p"/invite/#{invite.token}")

      {:ok, complete_lv, html} =
        lv
        |> element("button", "Accept invitation")
        |> render_click()
        |> follow_redirect(conn)

      assert Communities.get_membership(community, newcomer)
      assert html =~ "Before you continue"

      complete_lv
      |> form("#complete-profile-form", %{"custom_field" => %{field.id => "Tuba"}})
      |> render_submit()
      |> follow_redirect(conn, "/c/#{community.slug}")

      assert Communities.missing_required_custom_fields(community, newcomer) == []
    end

    test "a required custom field hard-blocks at join through the sign-in-then-accept path",
         %{conn: _conn} do
      {community, owner} = community_with_owner_fixture()

      {:ok, _field} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Instrument",
          "field_type" => "text",
          "required" => true
        })

      {:ok, invite} = Invitations.create_community_invite(owner, community)
      newcomer = user_fixture()

      conn = build_conn() |> log_in_user(newcomer) |> get(~p"/invite/#{invite.token}/accept")

      assert redirected_to(conn) == "/c/#{community.slug}/complete-profile"
      assert Communities.get_membership(community, newcomer)
    end
  end

  describe "community public page" do
    test "shows public_listed groups to visitors", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group_fixture(community, name: "Concerts", visibility: :public_listed)
      group_fixture(community, name: "Internal", visibility: :community)

      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}")

      assert html =~ "Concerts"
      refute html =~ "Internal"
    end
  end

  describe "member directory" do
    test "members see the directory; admins see management controls", %{conn: conn} do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)

      {:ok, _lv, member_html} =
        conn |> log_in_user(member) |> live(~p"/c/#{community.slug}/members")

      assert member_html =~ member.display_name
      refute member_html =~ "Make admin"

      {:ok, _lv, admin_html} =
        build_conn() |> log_in_user(owner) |> live(~p"/c/#{community.slug}/members")

      assert admin_html =~ "Make admin"
    end

    test "custom field answers respect visibility, and the filter narrows results", %{
      conn: conn
    } do
      {community, owner} = community_with_owner_fixture()
      viewer = member_fixture(community)
      tuba_player = member_fixture(community)
      oboe_player = member_fixture(community)

      {:ok, section} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Section",
          "field_type" => "single_select",
          "options" => ["Brass", "Woodwind"],
          "visibility" => "members"
        })

      {:ok, dietary} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Dietary needs",
          "field_type" => "text",
          "visibility" => "admins"
        })

      :ok =
        Communities.put_custom_field_values(tuba_player, community, %{
          section.id => "Brass",
          dietary.id => "Vegan"
        })

      :ok =
        Communities.put_custom_field_values(oboe_player, community, %{section.id => "Woodwind"})

      {:ok, lv, html} = conn |> log_in_user(viewer) |> live(~p"/c/#{community.slug}/members")

      assert html =~ "Section: Brass"
      refute html =~ "Dietary needs"
      refute html =~ "Vegan"

      filtered =
        lv
        |> form("#filter-#{section.id}", %{"value" => "Brass"})
        |> render_change()

      assert filtered =~ tuba_player.display_name
      refute filtered =~ oboe_player.display_name
    end
  end

  describe "group settings page" do
    test "plain members cannot open group settings", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      plain_member = group_member_fixture(group)

      assert {:error, {:live_redirect, %{to: destination}}} =
               conn
               |> log_in_user(plain_member)
               |> live(~p"/c/#{community.slug}/g/#{group.slug}/settings")

      assert destination == "/c/#{community.slug}/groups"
    end

    test "group admin approves a join request from settings", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, join_policy: :request_approval)
      group_admin = group_member_fixture(group, :admin)
      requester = member_fixture(community)
      {:ok, _request} = Groups.request_to_join(requester, group)

      {:ok, lv, html} =
        conn
        |> log_in_user(group_admin)
        |> live(~p"/c/#{community.slug}/g/#{group.slug}/settings")

      assert html =~ requester.display_name

      lv |> element("button", "Approve") |> render_click()

      assert Groups.get_membership(group, requester)
    end
  end
end
