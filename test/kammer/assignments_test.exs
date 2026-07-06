defmodule Kammer.AssignmentsTest do
  @moduledoc """
  Assignments (issue #41): the feature gate (OFF by default), the
  permission matrix, the claim/complete lifecycle, list ordering, and
  the comment engine's third subject.
  """

  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures

  alias Kammer.Assignments
  alias Kammer.Assignments.Assignment
  alias Kammer.Feed
  alias Kammer.Feed.Comment
  alias Kammer.Groups.Group
  alias Kammer.Repo

  defp assignments_group_context(extra_attrs \\ []) do
    {community, _owner} = community_with_owner_fixture()

    group =
      community
      |> group_fixture(extra_attrs)
      |> Group.features_changeset(%{"features" => ["feed", "assignments"]})
      |> Repo.update!()
      |> Map.put(:community, community)

    creator = group_member_fixture(group)
    member = group_member_fixture(group)

    %{community: community, group: group, creator: creator, member: member}
  end

  describe "the feature gate" do
    test "assignments ship OFF by default" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      member = group_member_fixture(group)

      refute Group.feature_enabled?(group, :assignments)

      assert {:error, :not_found} =
               Assignments.create_assignment(member, group, %{"title" => "Kaffe"})
    end

    test "gated-off assignments 404 on fetch" do
      %{group: group, creator: creator} = assignments_group_context()
      {:ok, assignment} = Assignments.create_assignment(creator, group, %{"title" => "Kaffe"})

      {:ok, _group} =
        group |> Group.features_changeset(%{"features" => ["feed"]}) |> Repo.update()

      assert {:error, :not_found} =
               Assignments.fetch_viewable_assignment(creator, assignment.id)
    end
  end

  describe "lifecycle" do
    test "create, claim (several people), complete, reopen" do
      %{group: group, creator: creator, member: member} = assignments_group_context()

      {:ok, assignment} =
        Assignments.create_assignment(creator, group, %{"title" => "Bage kage"})

      assert {:ok, _claim_one} = Assignments.claim(creator, assignment)
      assert {:ok, claim_two} = Assignments.claim(member, assignment)
      assert {:error, %Ecto.Changeset{}} = Assignments.claim(member, assignment)

      {:ok, loaded, _group} = Assignments.fetch_viewable_assignment(member, assignment.id)
      assert length(loaded.claims) == 2

      outsider = user_fixture()
      assert {:error, :unauthorized} = Assignments.claim(outsider, assignment)
      assert {:error, :unauthorized} = Assignments.unclaim(outsider, claim_two)

      assert {:ok, done} = Assignments.complete(member, assignment)
      assert Assignment.done?(done)
      assert done.completed_by_user_id == member.id

      assert {:error, :done} = Assignments.claim(member, done)
      assert {:error, :done} = Assignments.complete(member, done)

      assert {:ok, reopened} = Assignments.reopen(member, done)
      refute Assignment.done?(reopened)
      assert reopened.completed_by_user_id == nil
    end

    test "edit and delete are creator-or-moderator" do
      %{group: group, creator: creator, member: member} = assignments_group_context()
      moderator = group_member_fixture(group, :admin)

      {:ok, assignment} = Assignments.create_assignment(creator, group, %{"title" => "Kaffe"})

      assert {:error, :unauthorized} =
               Assignments.update_assignment(member, assignment, %{"title" => "Te"})

      assert {:ok, updated} =
               Assignments.update_assignment(creator, assignment, %{"title" => "Te"})

      assert updated.title == "Te"

      assert {:error, :unauthorized} = Assignments.delete_assignment(member, assignment)
      assert {:ok, _deleted} = Assignments.delete_assignment(moderator, assignment)
    end

    test "the list puts open before done, due dates first" do
      %{group: group, creator: creator} = assignments_group_context()
      soon = DateTime.add(DateTime.utc_now(:second), 24, :hour)
      later = DateTime.add(DateTime.utc_now(:second), 96, :hour)

      {:ok, no_due} = Assignments.create_assignment(creator, group, %{"title" => "Ingen frist"})

      {:ok, due_later} =
        Assignments.create_assignment(creator, group, %{"title" => "Senere", "due_at" => later})

      {:ok, due_soon} =
        Assignments.create_assignment(creator, group, %{"title" => "Snart", "due_at" => soon})

      {:ok, done} = Assignments.create_assignment(creator, group, %{"title" => "Færdig"})
      {:ok, _done} = Assignments.complete(creator, done)

      assert Enum.map(Assignments.list_assignments(group), & &1.id) ==
               [due_soon.id, due_later.id, no_due.id, done.id]
    end
  end

  describe "discussion (ADR 0007, third subject)" do
    test "comments attach, thread one level, and delete through the one engine" do
      %{group: group, creator: creator, member: member} = assignments_group_context()
      {:ok, assignment} = Assignments.create_assignment(creator, group, %{"title" => "Kaffe"})

      {:ok, comment} =
        Assignments.create_comment(member, assignment, %{"body_markdown" => "Jeg køber bønner"})

      assert comment.assignment_id == assignment.id
      assert comment.post_id == nil and comment.event_id == nil

      {:ok, reply} =
        Assignments.create_comment(creator, assignment, %{
          "body_markdown" => "Tak!",
          "parent_comment_id" => comment.id
        })

      assert reply.parent_comment_id == comment.id

      outsider = user_fixture()

      assert {:error, :unauthorized} =
               Assignments.create_comment(outsider, assignment, %{"body_markdown" => "Hej"})

      # Author soft-deletes through the shared engine.
      assert {:ok, deleted} = Feed.delete_comment(member, comment)
      assert deleted.deleted_at

      # Deleting the assignment removes the whole discussion.
      assert {:ok, _assignment} = Assignments.delete_assignment(creator, assignment)
      assert Repo.aggregate(Comment, :count) == 0
    end
  end
end
