defmodule KammerWeb.Api.ModerationController do
  @moduledoc """
  The moderation surface over the API (RFC 0001, issue #183): the open
  report queue, resolving (removes the content) or dismissing a report,
  community email bans, and the append-only audit log. Every decision
  runs through `Kammer.Moderation` / `Kammer.Audit` — the controller is
  transport only.

  No-oracle (#156/#161): the queue, ban list and audit log are silently
  empty for anyone who can't moderate, and a report or ban row the
  caller may not act on answers 404 to every verb — the same not-found
  shape a nonexistent id gets, so acting on a specific row never
  confirms it exists.
  """

  use KammerWeb, :controller

  alias Kammer.Accounts
  alias Kammer.Audit
  alias Kammer.Communities
  alias Kammer.Moderation
  alias Kammer.Moderation.CommunityBan
  alias Kammer.Moderation.Report
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @spec reports(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reports(conn, %{"community_slug" => slug}) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user
      reports = Moderation.list_open_reports(user, community)
      json(conn, %{data: Enum.map(reports, &Serializer.report/1)})
    end)
  end

  @spec resolve(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resolve(conn, %{"community_slug" => slug, "report_id" => report_id}) do
    act_on_report(conn, slug, report_id, &Moderation.resolve_report/2)
  end

  @spec dismiss(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def dismiss(conn, %{"community_slug" => slug, "report_id" => report_id}) do
    act_on_report(conn, slug, report_id, &Moderation.dismiss_report/2)
  end

  @spec bans(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def bans(conn, %{"community_slug" => slug}) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user
      bans = Moderation.list_bans(user, community)
      json(conn, %{data: Enum.map(bans, &Serializer.community_ban/1)})
    end)
  end

  @spec ban(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ban(conn, %{"community_slug" => slug, "user_id" => user_id} = params) do
    with_community(conn, slug, fn community ->
      actor = conn.assigns.current_scope.user

      case Accounts.get_user(user_id) do
        nil ->
          ApiError.send(conn, :not_found, "Not found.")

        target ->
          case Moderation.ban_member(actor, community, target, params["reason"]) do
            {:ok, ban} ->
              # The banning admin is the actor in hand — no need to
              # re-fetch it just to serialize `banned_by`.
              conn
              |> put_status(:created)
              |> json(%{data: Serializer.community_ban(%{ban | banned_by_user: actor})})

            error ->
              ApiError.from_result(conn, error)
          end
      end
    end)
  end

  def ban(conn, _params),
    do: ApiError.send(conn, :bad_request, "user_id is required.")

  @spec unban(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unban(conn, %{"community_slug" => slug, "ban_id" => ban_id}) do
    with_community(conn, slug, fn community ->
      actor = conn.assigns.current_scope.user

      with %CommunityBan{community_id: community_id} = existing <-
             Moderation.get_community_ban(ban_id),
           true <- community_id == community.id,
           {:ok, _lifted} <- Moderation.unban(actor, existing) do
        json(conn, %{data: %{status: "unbanned"}})
      else
        nil -> ApiError.send(conn, :not_found, "Not found.")
        false -> ApiError.send(conn, :not_found, "Not found.")
        # A ban the caller may not lift is hidden, not forbidden.
        {:error, :unauthorized} -> ApiError.send(conn, :not_found, "Not found.")
      end
    end)
  end

  @spec audit_log(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def audit_log(conn, %{"community_slug" => slug}) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user
      events = Audit.list_events(user, community)
      json(conn, %{data: Enum.map(events, &Serializer.audit_event/1)})
    end)
  end

  # Resolve/dismiss share the same shape: fetch the report, confirm it
  # belongs to this community, then run the mutator. A report the caller
  # may not act on is hidden (404), never a 403 that would confirm it.
  defp act_on_report(conn, slug, report_id, mutator) do
    with_community(conn, slug, fn community ->
      actor = conn.assigns.current_scope.user

      with %Report{community_id: community_id} = report <- Moderation.get_report(report_id),
           true <- community_id == community.id,
           {:ok, resolved} <- mutator.(actor, report) do
        json(conn, %{data: %{id: resolved.id, status: resolved.status}})
      else
        nil -> ApiError.send(conn, :not_found, "Not found.")
        false -> ApiError.send(conn, :not_found, "Not found.")
        {:error, :unauthorized} -> ApiError.send(conn, :not_found, "Not found.")
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
end
