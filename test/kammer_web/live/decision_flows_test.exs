defmodule KammerWeb.DecisionFlowsTest do
  @moduledoc """
  The decisions register end to end (issue #43): raise a motion from
  the register page, see the vote land in the feed, record the outcome.
  """

  use KammerWeb.ConnCase, async: true

  import Kammer.CommunitiesFixtures
  import Phoenix.LiveViewTest

  alias Kammer.Decisions
  alias Kammer.Decisions.Decision
  alias Kammer.Groups.Group
  alias Kammer.Repo

  defp decisions_context(_context) do
    {community, _owner} = community_with_owner_fixture()

    group =
      community
      |> group_fixture()
      |> Group.features_changeset(%{"features" => ["feed", "decisions"]})
      |> Repo.update!()
      |> Map.put(:community, community)

    proposer = group_member_fixture(group)
    moderator = group_member_fixture(group, :admin)

    %{community: community, group: group, proposer: proposer, moderator: moderator}
  end

  describe "the register journey" do
    setup :decisions_context

    test "raise a motion → vote in the feed → record the outcome", %{
      community: community,
      group: group,
      proposer: proposer,
      moderator: moderator
    } do
      proposer_conn = log_in_user(build_conn(), proposer)

      {:ok, register_lv, _html} =
        live(proposer_conn, ~p"/c/#{community.slug}/g/#{group.slug}/decisions")

      register_lv
      |> form("#new-decision-form",
        decision: %{
          title: "Hæv kontingentet",
          motion_markdown: "Kassen er tom.",
          with_vote: "true"
        }
      )
      |> render_submit()

      [decision] = Repo.all(Decision)
      assert decision.title == "Hæv kontingentet"

      # The vote landed in the feed as a normal post with a poll.
      {:ok, _feed_lv, feed_html} = live(proposer_conn, ~p"/c/#{community.slug}/g/#{group.slug}")
      assert feed_html =~ "Kassen er tom."
      assert feed_html =~ "For"

      # A moderator records the outcome.
      moderator_conn = log_in_user(build_conn(), moderator)

      {:ok, moderator_lv, moderator_html} =
        live(moderator_conn, ~p"/c/#{community.slug}/g/#{group.slug}/decisions")

      assert moderator_html =~ "Hæv kontingentet"

      moderator_lv
      |> form("#record-outcome-#{decision.id}", %{
        decision_id: decision.id,
        outcome: "adopted",
        outcome_note: "8 for, 1 imod"
      })
      |> render_submit()

      recorded = Repo.get!(Decision, decision.id)
      assert recorded.outcome == :adopted

      assert render(moderator_lv) =~ "8 for, 1 imod"
    end

    test "gated-off groups 404 the register", %{community: community, proposer: proposer} do
      plain_group = group_fixture(community)
      Kammer.Groups.add_member(plain_group, proposer)

      conn = log_in_user(build_conn(), proposer)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/c/#{community.slug}/g/#{plain_group.slug}/decisions")

      assert to == "/c/#{community.slug}"
    end

    test "the register survives outcome-less browsing", %{
      community: community,
      group: group,
      proposer: proposer
    } do
      {:ok, _decision} =
        Decisions.create_decision(proposer, group, %{"title" => "Åben sag"}, with_vote: false)

      conn = log_in_user(build_conn(), proposer)
      {:ok, _lv, html} = live(conn, ~p"/c/#{community.slug}/g/#{group.slug}/decisions")
      assert html =~ "Åben sag"
      assert html =~ "Open"
    end
  end
end
