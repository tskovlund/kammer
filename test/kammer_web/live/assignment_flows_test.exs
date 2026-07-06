defmodule KammerWeb.AssignmentFlowsTest do
  @moduledoc """
  Assignments end to end (issue #41): add from the list page, claim
  with one tap, finish, and discuss on the detail page.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Assignments
  alias Kammer.Assignments.Assignment
  alias Kammer.Groups.Group
  alias Kammer.Repo

  defp assignments_context(_context) do
    {community, _owner} = community_with_owner_fixture()

    group =
      community
      |> group_fixture()
      |> Group.features_changeset(%{"features" => ["feed", "assignments"]})
      |> Repo.update!()
      |> Map.put(:community, community)

    creator = group_member_fixture(group)
    member = group_member_fixture(group)

    %{community: community, group: group, creator: creator, member: member}
  end

  describe "the assignments journey" do
    setup :assignments_context

    test "add → claim → done", %{
      community: community,
      group: group,
      creator: creator,
      member: member
    } do
      creator_conn = log_in_user(build_conn(), creator)

      {:ok, creator_lv, _html} =
        live(creator_conn, ~p"/c/#{community.slug}/g/#{group.slug}/assignments")

      creator_lv
      |> form("#new-assignment-form", assignment: %{title: "Bage kage", due_for: ""})
      |> render_submit()

      [assignment] = Repo.all(Assignment)
      assert assignment.title == "Bage kage"

      member_conn = log_in_user(build_conn(), member)

      {:ok, member_lv, member_html} =
        live(member_conn, ~p"/c/#{community.slug}/g/#{group.slug}/assignments")

      assert member_html =~ "Bage kage"
      assert member_html =~ "Up for grabs"

      member_lv |> element("#claim-#{assignment.id}") |> render_click()
      assert Repo.get_by!(Kammer.Assignments.AssignmentClaim, assignment_id: assignment.id)

      member_lv |> element("#complete-#{assignment.id}") |> render_click()
      assert Repo.get!(Assignment, assignment.id).completed_at
    end

    test "detail page carries the discussion", %{
      community: community,
      group: group,
      creator: creator,
      member: member
    } do
      {:ok, assignment} =
        Assignments.create_assignment(creator, group, %{
          "title" => "Bestil noder",
          "notes_markdown" => "Helst inden fredag."
        })

      member_conn = log_in_user(build_conn(), member)

      {:ok, lv, html} =
        live(member_conn, ~p"/c/#{community.slug}/g/#{group.slug}/assignments/#{assignment.id}")

      assert html =~ "Bestil noder"
      assert html =~ "Helst inden fredag."

      lv
      |> form("#assignment-comment-form", %{body_markdown: "Jeg ringer til forlaget"})
      |> render_submit()

      assert render(lv) =~ "Jeg ringer til forlaget"

      comment = Repo.get_by!(Kammer.Feed.Comment, assignment_id: assignment.id)
      assert comment.author_user_id == member.id
    end

    test "gated-off groups 404 the pages", %{community: community, creator: creator} do
      plain_group = group_fixture(community)
      Kammer.Groups.add_member(plain_group, creator)

      conn = log_in_user(build_conn(), creator)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/c/#{community.slug}/g/#{plain_group.slug}/assignments")

      assert to == "/c/#{community.slug}"
    end
  end
end
