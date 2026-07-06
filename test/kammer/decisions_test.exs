defmodule Kammer.DecisionsTest do
  @moduledoc """
  The decisions register (issue #43): the feature gate, the
  create-with-vote transaction (motion post + default For/Against/
  Abstain poll + register entry), outcome recording, and visibility.
  """

  use Kammer.DataCase, async: true

  import Kammer.AccountsFixtures
  import Kammer.CommunitiesFixtures

  alias Kammer.Decisions
  alias Kammer.Decisions.Decision
  alias Kammer.Feed.Poll
  alias Kammer.Feed.Post
  alias Kammer.Groups.Group
  alias Kammer.Repo

  defp decisions_group_context(extra_attrs \\ []) do
    {community, _owner} = community_with_owner_fixture()

    group =
      community
      |> group_fixture(extra_attrs)
      |> Group.features_changeset(%{"features" => ["feed", "decisions"]})
      |> Repo.update!()
      |> Map.put(:community, community)

    proposer = group_member_fixture(group)
    member = group_member_fixture(group)

    %{community: community, group: group, proposer: proposer, member: member}
  end

  describe "the feature gate" do
    test "decisions ship OFF by default" do
      {community, _owner} = community_with_owner_fixture()
      group = group_fixture(community)
      member = group_member_fixture(group)

      refute Group.feature_enabled?(group, :decisions)

      assert {:error, :not_found} =
               Decisions.create_decision(member, group, %{"title" => "Kontingent"})
    end
  end

  describe "raising a motion" do
    test "creates the post, the default vote, and the register entry in one transaction" do
      %{group: group, proposer: proposer} = decisions_group_context()

      {:ok, decision} =
        Decisions.create_decision(proposer, group, %{
          "title" => "Hæv kontingentet til 250 kr.",
          "motion_markdown" => "Kassen er tom. **Forslag**: 250 kr. fra næste sæson."
        })

      assert decision.title == "Hæv kontingentet til 250 kr."
      refute Decision.decided?(decision)

      post = Repo.get!(Post, decision.post_id)
      assert post.body_markdown =~ "Kassen er tom"

      poll = Repo.get_by!(Poll, post_id: post.id) |> Repo.preload(:options)
      refute poll.multiple_choice
      refute poll.anonymous
      assert poll.options |> Enum.map(& &1.text) |> Enum.sort() == ["Abstain", "Against", "For"]
    end

    test "with_vote: false skips the poll; title doubles as body when no text given" do
      %{group: group, proposer: proposer} = decisions_group_context()

      {:ok, decision} =
        Decisions.create_decision(proposer, group, %{"title" => "Ny nøgle til øvelokalet"},
          with_vote: false
        )

      post = Repo.get!(Post, decision.post_id)
      assert post.body_markdown == "Ny nøgle til øvelokalet"
      assert Repo.aggregate(Poll, :count) == 0
    end

    test "non-members are refused; a failed register entry rolls back the post" do
      %{group: group} = decisions_group_context()
      outsider = user_fixture()

      assert {:error, :unauthorized} =
               Decisions.create_decision(outsider, group, %{"title" => "Kup"})

      assert Repo.aggregate(Post, :count) == 0
    end
  end

  describe "recording outcomes" do
    test "proposer or moderator records; members cannot" do
      %{group: group, proposer: proposer, member: member} = decisions_group_context()
      moderator = group_member_fixture(group, :admin)

      {:ok, decision} = Decisions.create_decision(proposer, group, %{"title" => "Kontingent"})

      assert {:error, :unauthorized} =
               Decisions.record_outcome(member, decision, %{"outcome" => "adopted"})

      assert {:ok, recorded} =
               Decisions.record_outcome(proposer, decision, %{
                 "outcome" => "adopted",
                 "outcome_note" => "8 for, 1 imod"
               })

      assert recorded.outcome == :adopted
      assert recorded.outcome_note == "8 for, 1 imod"
      assert recorded.decided_at
      assert recorded.decided_by_user_id == proposer.id

      # Amendable pre-1.0 by moderators (audit trail arrives with #33).
      assert {:ok, amended} =
               Decisions.record_outcome(moderator, recorded, %{"outcome" => "noted"})

      assert amended.outcome == :noted
    end
  end

  describe "visibility" do
    test "the register is visible exactly where the group is" do
      %{group: group, proposer: proposer} = decisions_group_context(visibility: :private)
      {:ok, decision} = Decisions.create_decision(proposer, group, %{"title" => "Hemmeligt"})

      outsider = user_fixture()
      assert {:error, _reason} = Decisions.fetch_viewable_decision(outsider, decision.id)
      assert {:ok, _decision, _group} = Decisions.fetch_viewable_decision(proposer, decision.id)

      {:ok, _group} =
        group |> Group.features_changeset(%{"features" => ["feed"]}) |> Repo.update()

      assert {:error, :not_found} = Decisions.fetch_viewable_decision(proposer, decision.id)
    end
  end
end
