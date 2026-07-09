defmodule KammerWeb.CommunityAdminTest do
  @moduledoc """
  LiveView tests for community/group administration surfaces and the
  remaining member-facing pages (bookmarks).
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Communities
  alias Kammer.Groups
  alias Kammer.Invitations

  describe "community settings" do
    setup %{conn: conn} do
      {community, owner} = community_with_owner_fixture()
      %{conn: log_in_user(conn, owner), community: community, owner: owner}
    end

    test "admin updates name and accent", %{conn: conn, community: community} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/settings")

      lv
      |> form("#community_settings_form", %{
        "community" => %{"name" => "Renamed Community", "accent_color" => "#AA3355"}
      })
      |> render_submit()

      updated = Communities.get_community_by_slug!(community.slug)
      assert updated.name == "Renamed Community"
      assert updated.accent_color == "#AA3355"
    end

    test "admin creates and revokes a community invite link", %{
      conn: conn,
      community: community,
      owner: owner
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/settings")

      lv |> element("button", "Create invite link") |> render_click()
      assert {:ok, [invite]} = Invitations.list_invites(owner, community)

      lv |> element(~s(button[phx-value-id="#{invite.id}"]), "Revoke") |> render_click()
      assert {:ok, []} = Invitations.list_invites(owner, community)
    end

    test "admin sends an email invite", %{conn: conn, community: community} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/settings")

      html =
        lv
        |> form("#email_invite_form", %{"invite" => %{"invited_email" => "tuba@example.com"}})
        |> render_submit()

      # Email invites are single-use (max_uses: 1); the shared invite
      # list must show the "/1" cap, not a bare use-count.
      assert html =~ "0/1"

      assert html =~ "tuba@example.com"
    end

    test "plain member is redirected", %{community: community} do
      member = member_fixture(community)

      assert {:error, {:live_redirect, %{to: destination}}} =
               build_conn() |> log_in_user(member) |> live(~p"/c/#{community.slug}/settings")

      assert destination == "/c/#{community.slug}"
    end
  end

  describe "member profile fields admin (SPEC §4)" do
    setup %{conn: conn} do
      {community, owner} = community_with_owner_fixture()
      %{conn: log_in_user(conn, owner), community: community, owner: owner}
    end

    test "admin adds, toggles required, and deletes a custom field", %{
      conn: conn,
      community: community
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/settings")

      lv
      |> form("#custom-field-form", %{
        "custom_field" => %{"label" => "Instrument", "field_type" => "text"}
      })
      |> render_submit()

      assert [field] = Communities.list_custom_fields(community)
      assert field.label == "Instrument"
      refute field.required

      html =
        lv
        |> element(~s(button[phx-value-id="#{field.id}"]), "Make required")
        |> render_click()

      assert html =~ "Required"
      assert hd(Communities.list_custom_fields(community)).required

      lv
      |> element(~s(button[phx-value-id="#{field.id}"]), "Delete")
      |> render_click()

      assert Communities.list_custom_fields(community) == []
    end

    test "adding a single-choice field without options fails validation", %{
      conn: conn,
      community: community
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/settings")

      lv
      |> form("#custom-field-form", %{
        "custom_field" => %{
          "label" => "Section",
          "field_type" => "single_select",
          "options" => ""
        }
      })
      |> render_submit()

      assert Communities.list_custom_fields(community) == []
    end
  end

  describe "group settings admin actions" do
    setup %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      group_admin = group_member_fixture(group, :admin)

      %{
        conn: log_in_user(conn, group_admin),
        community: community,
        group: group,
        group_admin: group_admin
      }
    end

    test "admin archives and unarchives", %{conn: conn, community: community, group: group} do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}/settings")

      lv |> element("button", "Archive group") |> render_click()
      assert Groups.get_group_by_slug!(community, group.slug).archived_at

      lv |> element("button", "Unarchive group") |> render_click()
      refute Groups.get_group_by_slug!(community, group.slug).archived_at
    end

    test "admin creates a group invite link", %{
      conn: conn,
      community: community,
      group: group,
      group_admin: group_admin
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}/settings")

      lv |> element("button", "Create invite link") |> render_click()
      assert {:ok, [_invite]} = Invitations.list_invites(group_admin, group)
    end

    test "admin edits policies through the form", %{
      conn: conn,
      community: community,
      group: group
    } do
      {:ok, lv, _html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}/settings")

      lv
      |> form("#group_settings_form", %{
        "group" => %{
          "name" => group.name,
          "slug" => group.slug,
          "posting_policy" => "admins_only"
        }
      })
      |> render_submit()

      assert Groups.get_group_by_slug!(community, group.slug).posting_policy == :admins_only
    end

    test "group owner can delete from settings", %{community: community} do
      group = group_fixture(community)
      group_owner = group_member_fixture(group, :owner)

      {:ok, lv, _html} =
        build_conn()
        |> log_in_user(group_owner)
        |> live(~p"/c/#{community.slug}/g/#{group.slug}/settings")

      lv |> element("button", "Delete group") |> render_click()

      assert {:error, :not_found} =
               Groups.fetch_viewable_group(group_owner, community, group.slug)
    end
  end

  describe "cross-instance bookmarks page" do
    test "add and remove a bookmark", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, html} = live(conn, ~p"/users/settings/servers")
      assert html =~ "No other servers yet"

      lv
      |> form("#bookmark_form", %{
        "instance_bookmark" => %{"name" => "Band HQ", "url" => "https://band.example.org"}
      })
      |> render_submit()

      assert [bookmark] = Communities.list_instance_bookmarks(user)

      lv |> element(~s(button[phx-value-id="#{bookmark.id}"])) |> render_click()
      assert [] = Communities.list_instance_bookmarks(user)
    end
  end

  describe "invite edge cases in the UI" do
    test "email-bound invite rejects the wrong signed-in account", %{conn: conn} do
      {community, owner} = community_with_owner_fixture()

      {:ok, invite} =
        Invitations.create_community_invite(owner, community, %{
          "invited_email" => "clarinet@example.com"
        })

      wrong_user = user_fixture()
      conn = log_in_user(conn, wrong_user)

      {:ok, lv, _html} = live(conn, ~p"/invite/#{invite.token}")
      html = lv |> element("button", "Accept invitation") |> render_click()

      assert html =~ "different email address"
      refute Communities.get_membership(community, wrong_user)
    end

    test "community home shows member view with groups", %{conn: conn} do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community, visibility: :community)
      member = group_member_fixture(group)

      {:ok, _lv, html} =
        conn |> log_in_user(member) |> live(~p"/c/#{community.slug}")

      assert html =~ group.name
      assert html =~ "Your groups"
    end
  end

  describe "required custom field nag banner (SPEC §4)" do
    test "nags a member once a field is made required after they joined, clears once answered",
         %{conn: conn} do
      {community, owner} = community_with_owner_fixture()
      member = member_fixture(community)

      {:ok, field} =
        Communities.create_custom_field(owner, community, %{
          "label" => "Instrument",
          "field_type" => "text"
        })

      conn = log_in_user(conn, member)
      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}")
      refute html =~ "Complete profile"

      {:ok, _field} =
        Communities.update_custom_field(owner, community, field, %{"required" => true})

      {:ok, lv, html} = live(conn, ~p"/c/#{community.slug}")
      assert html =~ "Complete profile"

      {:ok, complete_lv, _html} =
        lv |> element("a", "Complete profile") |> render_click() |> follow_redirect(conn)

      complete_lv
      |> form("#complete-profile-form", %{"custom_field" => %{field.id => "Tuba"}})
      |> render_submit()

      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}")
      refute html =~ "Complete profile"
    end
  end
end
