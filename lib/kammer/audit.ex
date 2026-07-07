defmodule Kammer.Audit do
  @moduledoc """
  The append-only audit log (SPEC §11): role changes, bans, deletions,
  settings changes, and community-admin overrides into groups — every
  entry a plain-language `summary` plus a stable `action` atom for
  filtering. Written by the context functions that perform these
  actions (`Communities`, `Groups`, `Moderation`); read here, gated to
  community admins.

  Deliberately not itself audited, and never blocks the action it
  records — a write failure here must not roll back the real
  operation, so `record/1` is fire-and-forget from the caller's view
  (it still raises on genuine bugs like a bad community_id, same as
  any other insert).
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Audit.AuditEvent
  alias Kammer.Authorization
  alias Kammer.Communities.Community
  alias Kammer.Repo

  @per_page 50

  @doc """
  Records an audit entry. `actor` may be `nil` (system-initiated
  actions have no human actor).
  """
  @spec record(Community.t() | Ecto.UUID.t(), User.t() | nil, String.t(), String.t(), map()) ::
          AuditEvent.t()
  def record(community_or_id, actor, action, summary, metadata \\ %{})

  def record(%Community{id: community_id}, actor, action, summary, metadata) do
    record(community_id, actor, action, summary, metadata)
  end

  def record(community_id, actor, action, summary, metadata) when is_binary(community_id) do
    Repo.insert!(%AuditEvent{
      community_id: community_id,
      actor_user_id: actor && actor.id,
      action: action,
      summary: summary,
      metadata: metadata
    })
  end

  @doc """
  A page of the community's audit log, newest first. Community admins
  only — everyone else gets an empty list, the same not-found-shaped
  silence the rest of the product uses for things you can't see.
  """
  @spec list_events(User.t() | nil, Community.t(), keyword()) :: [AuditEvent.t()]
  def list_events(actor, %Community{} = community, opts \\ []) do
    if Authorization.can?(actor, :manage_community, community) do
      Repo.all(
        from(event in AuditEvent,
          where: event.community_id == ^community.id,
          order_by: [desc: event.inserted_at],
          limit: ^Keyword.get(opts, :limit, @per_page),
          preload: [:actor_user]
        )
      )
    else
      []
    end
  end
end
