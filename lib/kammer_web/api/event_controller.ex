defmodule KammerWeb.Api.EventController do
  @moduledoc """
  Events over the API (RFC 0001, issue #180): listings, details and
  member RSVP, plus full write parity — create/edit/delete (single and
  recurring, ADR 0019), per-occurrence cancel/reinstate, signup-slot
  claim/unclaim and management, the shared comment engine, and
  reporting a comment to the moderators (issue #262) — all
  through the same context functions and authorization the UI uses; the
  controller adds transport, never policy.

  Every event-addressed write resolves the event through
  `Events.fetch_viewable_event/3`, so an event the caller cannot see
  answers 404 to every verb, exactly like one that doesn't exist (the
  no-oracle stance of #156/#161). Guest RSVP and guest slot claims stay
  web-only flows (they're for people without accounts; the API
  authenticates devices).
  """

  use KammerWeb, :controller

  alias Kammer.Communities
  alias Kammer.Events
  alias Kammer.Events.EventSlot
  alias Kammer.Events.SlotClaim
  alias Kammer.Feed
  alias Kammer.Feed.Comment
  alias Kammer.Groups
  alias Kammer.Moderation
  alias KammerWeb.Api.ReportIntake
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  # The event fields a caller may set on create/edit; programmatic
  # fields (community_id, group_id, created_by_user_id, series_id) are
  # never cast from the request — the context sets them.
  @event_fields ~w(title description_markdown starts_at ends_at all_day timezone location_name location_url)

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"community_slug" => slug}) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user
      events = Events.list_upcoming_events(user, community)
      json(conn, %{data: Enum.map(events, &Serializer.event/1)})
    end)
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"community_slug" => slug, "event_id" => event_id}) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      case fetch_visible_event(user, community, event_id) do
        {:ok, event} ->
          json(conn, %{data: Serializer.event(event, Events.get_rsvp(event, user), user)})

        error ->
          ApiError.from_result(conn, error)
      end
    end)
  end

  @spec rsvp(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rsvp(conn, %{"community_slug" => slug, "event_id" => event_id, "status" => status})
      when status in ["yes", "no", "maybe"] do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      with {:ok, event} <- fetch_visible_event(user, community, event_id),
           {:ok, rsvp} <- Events.rsvp(user, event, String.to_existing_atom(status)) do
        json(conn, %{data: %{event_id: event.id, status: rsvp.status}})
      else
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  def rsvp(conn, _params),
    do: ApiError.send(conn, :bad_request, "status must be one of yes, no, maybe.")

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_group(conn, slug, group_slug, fn community, group ->
      user = conn.assigns.current_scope.user
      attrs = Map.take(params, @event_fields)

      # A `recurrence` object (frequency + until) turns this into a
      # series (ADR 0019): one materialized Event per occurrence. The
      # response is the first occurrence, carrying its series_id — the
      # client refetches the list to see the whole series.
      result =
        case params["recurrence"] do
          %{} = recurrence ->
            with {:ok, [first | _]} <-
                   Events.create_recurring_event(user, group, attrs, recurrence),
                 do: {:ok, first}

          _ ->
            Events.create_event(user, group, attrs)
        end

      case result do
        {:ok, event} -> respond_created(conn, community, event.id, user)
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, params) do
    with_viewable_event(conn, params, fn community, event, user ->
      # Editing is always this-occurrence (ADR 0019): an occurrence is a
      # real, independently-editable row, and the domain has no
      # series-wide edit. "Move one date" is just a starts_at/ends_at edit.
      with {:ok, _updated} <- Events.update_event(user, event, Map.take(params, @event_fields)) do
        respond_with_event(conn, community, event.id, user)
      end
    end)
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, params) do
    with_viewable_event(conn, params, fn _community, event, user ->
      with {:ok, deleted} <- Events.delete_event(user, event) do
        json(conn, %{data: Serializer.event(deleted, nil, user)})
      end
    end)
  end

  @spec cancel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel(conn, params) do
    with_viewable_event(conn, params, fn community, event, user ->
      with {:ok, _cancelled} <- Events.cancel_occurrence(user, event) do
        respond_with_event(conn, community, event.id, user)
      end
    end)
  end

  @spec uncancel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def uncancel(conn, params) do
    with_viewable_event(conn, params, fn community, event, user ->
      with {:ok, _reinstated} <- Events.uncancel_occurrence(user, event) do
        respond_with_event(conn, community, event.id, user)
      end
    end)
  end

  @spec create_slot(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_slot(conn, params) do
    with_viewable_event(conn, params, fn community, event, user ->
      with {:ok, _slot} <-
             Events.create_slot(user, event, Map.take(params, ["title", "capacity"])) do
        respond_with_event(conn, community, event.id, user)
      end
    end)
  end

  @spec delete_slot(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete_slot(conn, %{"slot_id" => slot_id} = params) do
    with_viewable_event(conn, params, fn community, event, user ->
      with_event_slot(event, slot_id, fn slot ->
        with {:ok, _deleted} <- Events.delete_slot(user, slot) do
          respond_with_event(conn, community, event.id, user)
        end
      end)
    end)
  end

  @spec claim_slot(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def claim_slot(conn, %{"slot_id" => slot_id} = params) do
    with_viewable_event(conn, params, fn community, event, user ->
      with_event_slot(event, slot_id, fn slot ->
        with {:ok, _claim} <- Events.claim_slot(user, slot) do
          respond_with_event(conn, community, event.id, user)
        end
      end)
    end)
  end

  @spec unclaim_slot(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unclaim_slot(conn, %{"slot_id" => slot_id} = params) do
    with_viewable_event(conn, params, fn community, event, user ->
      with_event_slot(event, slot_id, fn slot ->
        # Releasing a claim over the API is always your own; a full slot
        # a manager wants gone is handled by deleting the slot.
        case Events.get_slot_claim(slot.id, user.id) do
          %SlotClaim{} = claim ->
            with {:ok, _released} <- Events.unclaim_slot(user, claim) do
              respond_with_event(conn, community, event.id, user)
            end

          nil ->
            {:error, :not_found}
        end
      end)
    end)
  end

  @spec create_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_comment(conn, params) do
    with_viewable_event(conn, params, fn _community, event, user ->
      attrs = Map.take(params, ["body_markdown", "parent_comment_id"])

      with {:ok, comment} <- Events.create_comment(user, event, attrs) do
        conn
        |> put_status(201)
        |> json(%{data: Serializer.comment(comment, user)})
      end
    end)
  end

  @spec update_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_comment(conn, %{"comment_id" => comment_id} = params) do
    with_event_comment(conn, params, comment_id, fn community, event, comment, user ->
      with {:ok, _comment} <-
             Feed.edit_comment(user, comment, Map.take(params, ["body_markdown"])) do
        respond_with_comment(conn, community, event.id, comment.id, user)
      end
    end)
  end

  @spec delete_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete_comment(conn, %{"comment_id" => comment_id} = params) do
    with_event_comment(conn, params, comment_id, fn _community, _event, comment, user ->
      with {:ok, deleted} <- Feed.delete_comment(user, comment) do
        # Hard-deleted (moderator) comments no longer exist; answer with
        # the tombstone shape built from the struct in hand — same as the
        # post-comment path.
        tombstone = %{comment | deleted_at: deleted.deleted_at || DateTime.utc_now(:second)}
        json(conn, %{data: Serializer.comment(tombstone, user)})
      end
    end)
  end

  @spec react_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def react_comment(conn, %{"comment_id" => comment_id, "emoji" => emoji} = params)
      when is_binary(emoji) do
    with_event_comment(conn, params, comment_id, fn community, event, comment, user ->
      with {:ok, _change} <- Feed.toggle_reaction(user, comment, emoji) do
        respond_with_comment(conn, community, event.id, comment.id, user)
      end
    end)
  end

  def react_comment(conn, _params),
    do: ApiError.send(conn, :bad_request, "Send an `emoji` string.")

  @spec report_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def report_comment(conn, %{"comment_id" => comment_id, "reason" => reason} = params)
      when is_binary(reason) do
    with_event_comment(conn, params, comment_id, fn _community, _event, comment, user ->
      ReportIntake.respond(conn, Moderation.report_comment(user, comment, reason))
    end)
  end

  def report_comment(conn, _params),
    do: ReportIntake.reject_missing_reason(conn)

  ## Internals

  # Genuine no-oracle (#156/#161): `fetch_viewable_event`'s only
  # `:unauthorized` comes from the `:view_group` gate — i.e. the event
  # is hidden — so at the API boundary that reads as `:not_found`,
  # indistinguishable from a nonexistent event. A visible-but-forbidden
  # *write* still 403s: that check runs after this, on an event whose
  # existence the caller already knows.
  defp fetch_visible_event(user, community, event_id) do
    case Events.fetch_viewable_event(user, community, event_id) do
      {:error, :unauthorized} -> {:error, :not_found}
      other -> other
    end
  end

  defp with_community(conn, slug, fun) do
    case Communities.get_community_by_slug(slug) do
      nil -> ApiError.send(conn, :not_found, "Not found.")
      community -> fun.(community)
    end
  end

  defp with_group(conn, community_slug, group_slug, fun) do
    user = conn.assigns.current_scope.user

    with %Communities.Community{} = community <-
           Communities.get_community_by_slug(community_slug),
         {:ok, group} <- Groups.fetch_viewable_group(user, community, group_slug) do
      fun.(community, group)
    else
      nil -> ApiError.send(conn, :not_found, "Not found.")
      error -> ApiError.from_result(conn, error)
    end
  end

  # The shared head of every event-addressed write: resolve the
  # community, then the event exactly as the caller sees it — an
  # invisible event 404s before any permission check could leak that it
  # exists. The callback's error tuples fall through to the one envelope.
  defp with_viewable_event(conn, %{"community_slug" => slug, "event_id" => event_id}, fun) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      with {:ok, event} <- fetch_visible_event(user, community, event_id),
           %Plug.Conn{} = responded <- fun.(community, event, user) do
        responded
      else
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  # A slot that isn't this event's answers 404, the same as a missing
  # one — the slot id is only meaningful within its event.
  defp with_event_slot(%{id: event_id}, slot_id, fun) do
    case Events.get_slot(slot_id) do
      %EventSlot{event_id: ^event_id} = slot -> fun.(slot)
      _mismatch_or_missing -> {:error, :not_found}
    end
  end

  defp with_event_comment(conn, params, comment_id, fun) do
    with_viewable_event(conn, params, fn community, event, user ->
      # The visible event's preloaded comments are exactly the ones the
      # caller may see, so a comment that isn't among them 404s here.
      case find_comment(event, comment_id) do
        %Comment{} = comment -> fun.(community, event, comment, user)
        nil -> {:error, :not_found}
      end
    end)
  end

  defp find_comment(%{comments: comments}, comment_id) when is_list(comments),
    do: Enum.find(comments, &(&1.id == comment_id))

  defp find_comment(_event, _comment_id), do: nil

  defp respond_created(conn, community, event_id, user) do
    case fetch_visible_event(user, community, event_id) do
      {:ok, event} ->
        conn
        |> put_status(201)
        |> json(%{data: Serializer.event(event, Events.get_rsvp(event, user), user)})

      error ->
        ApiError.from_result(conn, error)
    end
  end

  defp respond_with_event(conn, community, event_id, user) do
    case fetch_visible_event(user, community, event_id) do
      {:ok, event} ->
        json(conn, %{data: Serializer.event(event, Events.get_rsvp(event, user), user)})

      error ->
        ApiError.from_result(conn, error)
    end
  end

  defp respond_with_comment(conn, community, event_id, comment_id, user) do
    with {:ok, event} <- fetch_visible_event(user, community, event_id),
         %Comment{} = comment <- find_comment(event, comment_id) || :gone do
      json(conn, %{data: Serializer.comment(comment, user)})
    else
      _gone -> {:error, :not_found}
    end
  end
end
