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
  The capped recent slice of the community's audit log, newest first —
  the context tests' read-back helper; the API paginates via
  `list_events_page/4` instead. Community admins only — everyone else
  gets an empty list, the same not-found-shaped silence the rest of
  the product uses for things you can't see.
  """
  @spec list_events(User.t() | nil, Community.t()) :: [AuditEvent.t()]
  def list_events(actor, %Community{} = community) do
    if Authorization.can?(actor, :manage_community, community) do
      Repo.all(
        from(event in AuditEvent,
          where: event.community_id == ^community.id,
          order_by: [desc: event.inserted_at],
          limit: @per_page,
          preload: [:actor_user]
        )
      )
    else
      []
    end
  end

  @doc """
  One cursor page of the community's audit log, newest first (issue
  #340) — same contract as `Kammer.Notifications.list_notifications_page/3`:
  `{events, next_cursor}`, `next_cursor` `nil` on the last page. Gated
  the same way as `list_events/2`: anyone but a community admin sees
  an empty page with no cursor, never an error that would confirm the
  log exists.
  """
  @spec list_events_page(
          User.t() | nil,
          Community.t(),
          {DateTime.t(), Ecto.UUID.t()} | nil,
          pos_integer()
        ) :: {[AuditEvent.t()], {DateTime.t(), Ecto.UUID.t()} | nil}
  def list_events_page(actor, %Community{} = community, cursor, limit)
      when limit > 0 and limit <= 100 do
    if Authorization.can?(actor, :manage_community, community) do
      query =
        from(event in AuditEvent,
          where: event.community_id == ^community.id,
          order_by: [desc: event.inserted_at, desc: event.id],
          limit: ^(limit + 1),
          preload: [:actor_user]
        )

      query =
        case cursor do
          nil ->
            query

          {cursor_at, cursor_id} ->
            from(event in query,
              where:
                event.inserted_at < ^cursor_at or
                  (event.inserted_at == ^cursor_at and event.id < ^cursor_id)
            )
        end

      events = Repo.all(query)

      case Enum.split(events, limit) do
        {page, []} -> {page, nil}
        {page, _more} -> {page, page |> List.last() |> then(&{&1.inserted_at, &1.id})}
      end
    else
      {[], nil}
    end
  end
end
