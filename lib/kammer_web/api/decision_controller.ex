defmodule KammerWeb.Api.DecisionController do
  @moduledoc """
  The decisions register over the API (RFC 0001, issue #184): browse a
  group's register, raise a motion (a feed post with the default
  For/Against/Abstain vote, ADR 0007), read one, and record its outcome.
  Every decision runs through `Kammer.Decisions` and
  `Kammer.Authorization`; the controller adds transport, never policy.

  Feature-gated per group (`:decisions`, ADR 0016): a group without the
  tool is unreachable. No-oracle (#156/#161): a register entry the caller
  may not see answers 404; a visible one the caller may not decide still
  403s.
  """

  use KammerWeb, :controller

  alias Kammer.Communities
  alias Kammer.Decisions
  alias KammerWeb.Api.GroupGate
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @feature :decisions

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"community_slug" => slug, "group_slug" => group_slug}) do
    with_feature_group(conn, slug, group_slug, fn _community, group, user ->
      decisions = Decisions.list_decisions(group)

      json(conn, %{
        data: Enum.map(decisions, &Serializer.decision(&1, capabilities(user, &1, group)))
      })
    end)
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_feature_group(conn, slug, group_slug, fn _community, group, user ->
      opts = if params["with_vote"] == false, do: [with_vote: false], else: []
      attrs = Map.take(params, ["title", "motion_markdown"])

      with {:ok, decision} <- Decisions.create_decision(user, group, attrs, opts) do
        conn
        |> put_status(201)
        |> json(%{data: Serializer.decision(decision, capabilities(user, decision, group))})
      end
    end)
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    with_decision(conn, params, fn decision, group, user ->
      json(conn, %{data: Serializer.decision(decision, capabilities(user, decision, group))})
    end)
  end

  @spec record_outcome(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def record_outcome(conn, params) do
    with_decision(conn, params, fn decision, _group, user ->
      attrs = Map.take(params, ["outcome", "outcome_note"])

      with {:ok, _recorded} <- Decisions.record_outcome(user, decision, attrs) do
        respond_with_decision(conn, decision.id, user)
      end
    end)
  end

  ## Internals

  # Recording the outcome depends on the motion's post author, so
  # `can_record_outcome?/3` reads it — one query per entry, over a small
  # register, kept out of the query-free serializer.
  defp capabilities(user, decision, group) do
    if Decisions.can_record_outcome?(user, decision, group), do: ["record_outcome"], else: []
  end

  # No-oracle (#156/#161, #339): a missing community, a missing group,
  # a group the caller may not even *view*, and a group with the tool
  # off all fold into the same 404 via `GroupGate.fetch/4`.
  defp with_feature_group(conn, community_slug, group_slug, fun) do
    user = conn.assigns.current_scope.user

    case GroupGate.fetch(user, community_slug, group_slug, feature: @feature) do
      {:ok, community, group} -> fun.(community, group, user)
      {:error, :not_found} -> ApiError.send(conn, :not_found, "Not found.")
    end
  end

  defp with_decision(conn, %{"community_slug" => slug, "decision_id" => id}, fun) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      with {:ok, decision, group} <- fetch_visible_decision(user, id),
           true <- decision.community_id == community.id,
           %Plug.Conn{} = responded <- fun.(decision, group, user) do
        responded
      else
        false -> ApiError.send(conn, :not_found, "Not found.")
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  defp with_community(conn, slug, fun) do
    case Communities.get_community_by_slug(slug) do
      nil -> ApiError.send(conn, :not_found, "Not found.")
      community -> fun.(community)
    end
  end

  defp fetch_visible_decision(user, id) do
    case Decisions.fetch_viewable_decision(user, id) do
      {:error, :unauthorized} -> {:error, :not_found}
      other -> other
    end
  end

  defp respond_with_decision(conn, id, user) do
    case fetch_visible_decision(user, id) do
      {:ok, decision, group} ->
        json(conn, %{data: Serializer.decision(decision, capabilities(user, decision, group))})

      error ->
        ApiError.from_result(conn, error)
    end
  end
end
