defmodule Kammer.Decisions do
  @moduledoc """
  The decisions register (issue #43, collaborative track #17): a motion
  is a feed post — Markdown text plus, by default, a For/Against/
  Abstain vote using the existing poll machinery — and the register
  records what came of it. Browsable per group, built for sealed board
  groups where institutional memory matters most.

  Feature-gated per group (`:decisions`, OFF by default). Permissions
  delegate to `Kammer.Authorization`: raising a motion follows the
  posting policy, recording the outcome is proposer-or-moderator.
  """

  use Gettext, backend: KammerWeb.Gettext

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Authorization
  alias Kammer.Decisions.Decision
  alias Kammer.Feed
  alias Kammer.Groups.Group
  alias Kammer.Repo

  @doc """
  Raises a motion: creates the feed post (with the default
  For/Against/Abstain vote unless `with_vote: false`) and the register
  entry in one transaction. The post body is the motion text.
  """
  @spec create_decision(User.t(), Group.t(), map(), keyword()) ::
          {:ok, Decision.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :not_found | term()}
  def create_decision(%User{} = proposer, %Group{} = group, attrs, opts \\ []) do
    with :ok <- Authorization.feature_gate(group, :decisions),
         :ok <- Authorization.authorize(proposer, :post_in_group, group) do
      post_attrs = %{
        "body_markdown" => motion_body(attrs),
        "poll" => if(Keyword.get(opts, :with_vote, true), do: vote_poll_attrs())
      }

      Repo.transact(fn ->
        with {:ok, post} <- Feed.create_post(proposer, group, post_attrs),
             {:ok, decision} <-
               %Decision{
                 community_id: group.community_id,
                 group_id: group.id,
                 post_id: post.id
               }
               |> Decision.changeset(attrs)
               |> Repo.insert() do
          {:ok, decision}
        end
      end)
    end
  end

  @doc """
  The group's register, newest motions first.
  """
  @spec list_decisions(Group.t()) :: [Decision.t()]
  def list_decisions(%Group{} = group) do
    Repo.all(
      from(decision in Decision,
        where: decision.group_id == ^group.id,
        order_by: [desc: decision.inserted_at],
        preload: [:decided_by_user]
      )
    )
  end

  @doc """
  Fetches a decision the actor may see (view on the host group +
  feature gate).
  """
  @spec fetch_viewable_decision(User.t() | nil, Ecto.UUID.t()) ::
          {:ok, Decision.t(), Group.t()} | {:error, :not_found | :unauthorized}
  def fetch_viewable_decision(actor, decision_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(decision_id),
         %Decision{} = decision <- Repo.get(Decision, decision_id),
         %Group{} = group <- Repo.get(Group, decision.group_id),
         :ok <- Authorization.feature_gate(group, :decisions),
         :ok <- Authorization.authorize(actor, :view_group, group) do
      {:ok, Repo.preload(decision, :decided_by_user), group}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      _missing_or_invalid -> {:error, :not_found}
    end
  end

  @doc """
  Whether the actor may record the outcome — the motion's proposer or
  a group moderator.
  """
  @spec can_record_outcome?(User.t() | nil, Decision.t(), Group.t()) :: boolean()
  def can_record_outcome?(actor, %Decision{} = decision, %Group{} = group) do
    proposer_id = decision.post_id |> Feed.get_post() |> then(&(&1 && &1.author_user_id))

    Authorization.can_manage_own_resource?(actor, proposer_id, group)
  end

  @doc """
  Records (or amends, pre-1.0) the outcome. An audit trail for
  amendments arrives with the #33 audit-log work.
  """
  @spec record_outcome(User.t(), Decision.t(), map()) ::
          {:ok, Decision.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def record_outcome(%User{} = actor, %Decision{} = decision, attrs) do
    group = Repo.get!(Group, decision.group_id)

    if can_record_outcome?(actor, decision, group) do
      decision
      |> Decision.outcome_changeset(attrs)
      |> Ecto.Changeset.put_change(:decided_at, DateTime.utc_now(:second))
      |> Ecto.Changeset.put_change(:decided_by_user_id, actor.id)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  defp motion_body(attrs) do
    case attrs["motion_markdown"] do
      body when is_binary(body) and body != "" -> body
      _missing -> attrs["title"]
    end
  end

  # The board-vote default: single choice, named votes (this is a
  # register, not a ballot box), no closing time — closing is the
  # human act of recording the outcome. Option texts are stored
  # content, so they're rendered once, in the instance's default
  # locale, at creation time.
  defp vote_poll_attrs do
    KammerWeb.Gettext.with_instance_locale(fn ->
      %{
        "multiple_choice" => false,
        "anonymous" => false,
        "options" => %{
          "0" => %{"text" => gettext("For"), "position" => "0"},
          "1" => %{"text" => gettext("Against"), "position" => "1"},
          "2" => %{"text" => gettext("Abstain"), "position" => "2"}
        }
      }
    end)
  end
end
