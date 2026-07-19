defmodule KammerWeb.Api.ModerationController do
  @moduledoc """
  The moderation surface over the API (RFC 0001, issue #183): the open
  report queue, resolving (removes the content) or dismissing a report,
  community email bans, instance-wide email bans (issue #259), and the
  append-only audit log. Every decision runs through `Kammer.Moderation`
  / `Kammer.Audit` — the controller is transport only.

  No-oracle (#156/#161): the queue, ban list and audit log are silently
  empty for anyone who can't moderate, and a report or ban row the
  caller may not act on answers 404 to every verb — the same not-found
  shape a nonexistent id gets, so acting on a specific row never
  confirms it exists.
  """

  use KammerWeb, :controller

  alias Kammer.Accounts
  alias Kammer.Audit
  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Moderation
  alias Kammer.Moderation.CommunityBan
  alias Kammer.Moderation.InstanceBan
  alias Kammer.Moderation.Report
  alias KammerWeb.Api.Pagination
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  # The audit log predates cursor pagination (issue #340) at a 50-row
  # default; kept on migrating to `Pagination` rather than dropping to
  # the shared 25, so an unpaginated existing client sees no change.
  @audit_default_limit 50

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

      # Authorize before resolving the target: a non-admin must be
      # refused (403) before any user lookup, so the 404-for-missing vs
      # something-else-for-real difference can't become a user-existence
      # oracle. Ban-create is a community-level action with no hidden
      # row, so 403 (not 404) is the honest answer for a denied caller;
      # `ban_member` re-checks authorization as the source of truth.
      with :ok <- Authorization.authorize(actor, :manage_community, community),
           target when not is_nil(target) <- Accounts.get_user(user_id),
           {:ok, ban} <- Moderation.ban_member(actor, community, target, params["reason"]) do
        # The banning admin is the actor in hand — no need to re-fetch it
        # just to serialize `banned_by`.
        conn
        |> put_status(:created)
        |> json(%{data: Serializer.community_ban(%{ban | banned_by_user: actor})})
      else
        nil -> ApiError.send(conn, :not_found, "Not found.")
        error -> ApiError.from_result(conn, error)
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
        nil ->
          ApiError.send(conn, :not_found, "Not found.")

        false ->
          ApiError.send(conn, :not_found, "Not found.")

        # A ban the caller may not lift is hidden, not forbidden; a ban a
        # concurrent lift already removed is a neutral 404, not a 500.
        {:error, reason} when reason in [:unauthorized, :not_found] ->
          ApiError.send(conn, :not_found, "Not found.")
      end
    end)
  end

  ## Instance-wide bans (issue #259, SPEC §11) — the API twin of
  ## InstanceLive.Moderation. Being an operator is not a secret, and
  ## there is no hidden row behind the list or the create, so a denied
  ## caller gets an honest 403 (mirroring `GET /instance/settings`);
  ## lifting a specific ban keeps the community pattern — a ban the
  ## caller may not lift is hidden (404), never confirmed.

  @spec instance_bans(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def instance_bans(conn, _params) do
    user = conn.assigns.current_scope.user

    if Authorization.instance_operator?(user) do
      bans = Moderation.list_instance_bans(user)
      json(conn, %{data: Enum.map(bans, &Serializer.instance_ban/1)})
    else
      ApiError.send(conn, :forbidden, "You are not allowed to do that.")
    end
  end

  @spec instance_ban(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def instance_ban(conn, %{"email" => email} = params) when is_binary(email) do
    actor = conn.assigns.current_scope.user

    case Moderation.ban_instance(actor, email, normalize_reason(params["reason"])) do
      {:ok, ban} ->
        # `ban_instance` already revoked the banned account's device
        # tokens; sever its open sockets now too so a live stream can't
        # outlive the credential (as account deletion / email change do).
        # A no-op when the banned address has no account.
        banned_user = Accounts.get_user_by_email(ban.email)

        if banned_user do
          KammerWeb.Endpoint.broadcast("api_user_socket:#{banned_user.id}", "disconnect", %{})
        end

        # The banning operator is the actor in hand — no re-fetch to
        # serialize `banned_by`.
        conn
        |> put_status(:created)
        |> json(%{data: Serializer.instance_ban(%{ban | banned_by_user: actor})})

      error ->
        ApiError.from_result(conn, error)
    end
  end

  def instance_ban(conn, _params),
    do: ApiError.send(conn, :bad_request, "email is required.")

  @spec instance_unban(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def instance_unban(conn, %{"ban_id" => ban_id}) do
    actor = conn.assigns.current_scope.user

    with %InstanceBan{} = ban <- Moderation.get_instance_ban(ban_id),
         {:ok, _lifted} <- Moderation.unban_instance(actor, ban) do
      json(conn, %{data: %{status: "unbanned"}})
    else
      nil ->
        ApiError.send(conn, :not_found, "Not found.")

      # A ban the caller may not lift is hidden, not forbidden; a ban a
      # concurrent lift already removed is a neutral 404, not a 500.
      {:error, reason} when reason in [:unauthorized, :not_found] ->
        ApiError.send(conn, :not_found, "Not found.")
    end
  end

  @spec instance_audit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def instance_audit(conn, params) do
    user = conn.assigns.current_scope.user

    # Operator-only, and an operator is not a secret — a denied caller gets
    # an honest 403, mirroring `instance_bans` (the context reader also
    # gates, so the list can't leak if reached another way).
    if Authorization.instance_operator?(user) do
      {events, next_cursor} =
        Audit.list_instance_events_page(
          user,
          Pagination.decode(params["after"]),
          Pagination.limit(params, @audit_default_limit)
        )

      json(conn, %{
        data: Enum.map(events, &Serializer.audit_event/1),
        next_cursor: Pagination.encode(next_cursor)
      })
    else
      ApiError.send(conn, :forbidden, "You are not allowed to do that.")
    end
  end

  @spec audit_log(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def audit_log(conn, %{"community_slug" => slug} = params) do
    with_community(conn, slug, fn community ->
      user = conn.assigns.current_scope.user

      {events, next_cursor} =
        Audit.list_events_page(
          user,
          community,
          Pagination.decode(params["after"]),
          Pagination.limit(params, @audit_default_limit)
        )

      json(conn, %{
        data: Enum.map(events, &Serializer.audit_event/1),
        next_cursor: Pagination.encode(next_cursor)
      })
    end)
  end

  # An all-whitespace reason is no reason — the same normalization the
  # LiveView form applies before `ban_instance/3`.
  defp normalize_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_reason(_other), do: nil

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
