defmodule KammerWeb.Api.GroupMemberController do
  @moduledoc """
  Group membership over the API (SPEC §3, issue #182): the member list,
  joining per the group's join policy (open joins directly,
  request-approval files a request, invite-only refuses), leaving,
  admin role changes and removals, the join-request queue, and the
  member's per-group notification level (SPEC §9) — all through the
  same context functions and authorization the group LiveViews use;
  the controller adds transport, never policy.

  No-oracle: a group the caller can't see 403s at resolution exactly
  like the feed/event/file routes. Within a visible group the member
  list is visible to every viewer, so member-addressed writes answer
  an honest 403 when refused — but join requests are admin-only
  information, so approving or denying one without that right answers
  404 for every request id.
  """

  use KammerWeb, :controller

  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Groups
  alias Kammer.Groups.GroupJoinRequest
  alias Kammer.Groups.GroupMembership
  alias Kammer.Notifications
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @roles ~w(owner admin member)
  @levels ~w(everything highlights mentions_only muted)

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    with_group(conn, params, fn group, user ->
      with {:ok, memberships} <- Groups.list_members(user, group) do
        json(conn, %{data: Enum.map(memberships, &Serializer.group_member/1)})
      end
    end)
  end

  @spec join(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def join(conn, params) do
    with_group(conn, params, fn group, user ->
      # Idempotent PUT: already a member reads as "joined", a second
      # request while one is pending reads as "requested" — never a
      # refusal or a unique-constraint error.
      cond do
        Groups.get_membership(group, user) ->
          json(conn, %{status: "joined"})

        group.join_policy == :open ->
          with {:ok, _membership} <- Groups.join_group(user, group) do
            json(conn, %{status: "joined"})
          end

        group.join_policy == :request_approval and Groups.pending_join_request?(user, group) ->
          json(conn, %{status: "requested"})

        group.join_policy == :request_approval ->
          with {:ok, _request} <- Groups.request_to_join(user, group, params["message"]) do
            json(conn, %{status: "requested"})
          end

        true ->
          # invite_only: visible, but joining needs an invite — an
          # honest 403 on a group the caller already sees.
          {:error, :unauthorized}
      end
    end)
  end

  @spec leave(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def leave(conn, params) do
    with_group(conn, params, fn group, user ->
      with {:ok, _membership} <- Groups.leave_group(user, group) do
        json(conn, %{status: "left"})
      end
    end)
  end

  @spec update_role(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_role(conn, %{"user_id" => user_id, "role" => role} = params)
      when role in @roles do
    with_member(conn, params, user_id, fn group, membership, user ->
      with {:ok, updated} <-
             Groups.update_member_role(user, group, membership, String.to_existing_atom(role)) do
        json(conn, %{data: %{user_id: updated.user_id, role: updated.role}})
      end
    end)
  end

  def update_role(conn, _params),
    do: ApiError.send(conn, :bad_request, "role must be one of owner, admin, member.")

  @spec remove(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def remove(conn, %{"user_id" => user_id} = params) do
    with_member(conn, params, user_id, fn group, membership, user ->
      with {:ok, _removed} <- Groups.remove_member(user, group, membership) do
        json(conn, %{status: "removed"})
      end
    end)
  end

  @spec index_join_requests(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index_join_requests(conn, params) do
    with_group(conn, params, fn group, user ->
      with {:ok, requests} <- Groups.list_pending_join_requests(user, group) do
        json(conn, %{data: Enum.map(requests, &Serializer.join_request/1)})
      end
    end)
  end

  @spec approve_join_request(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def approve_join_request(conn, %{"request_id" => request_id} = params) do
    with_join_request(conn, params, request_id, fn group, request, user ->
      with {:ok, _membership} <- Groups.approve_join_request(user, group, request) do
        json(conn, %{status: "approved"})
      end
    end)
  end

  @spec deny_join_request(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def deny_join_request(conn, %{"request_id" => request_id} = params) do
    with_join_request(conn, params, request_id, fn group, request, user ->
      with {:ok, _denied} <- Groups.deny_join_request(user, group, request) do
        json(conn, %{status: "denied"})
      end
    end)
  end

  @spec show_notification_level(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show_notification_level(conn, params) do
    with_group(conn, params, fn group, user ->
      json(conn, %{data: level_payload(Notifications.effective_level(user, group), group)})
    end)
  end

  @spec update_notification_level(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_notification_level(conn, %{"level" => level} = params) when level in @levels do
    with_group(conn, params, fn group, user ->
      with {:ok, preference} <-
             Notifications.set_level(user, group, String.to_existing_atom(level)) do
        json(conn, %{data: level_payload(preference.level, group)})
      end
    end)
  end

  def update_notification_level(conn, _params),
    do:
      ApiError.send(
        conn,
        :bad_request,
        "level must be one of everything, highlights, mentions_only, muted."
      )

  ## Internals

  defp level_payload(level, group) do
    %{level: level, default_level: Notifications.default_level(group)}
  end

  # Member existence within a visible group is visible information
  # (the member list requires only `:view_group`), so a missing
  # membership 404s and a refused write 403s honestly.
  defp with_member(conn, params, user_id, fun) do
    with_group(conn, params, fn group, user ->
      case Groups.get_membership_by_user_id(group, user_id) do
        %GroupMembership{} = membership -> fun.(group, membership, user)
        nil -> {:error, :not_found}
      end
    end)
  end

  # Join requests are admin-only information: without
  # `:approve_group_members` every request id answers 404, the same as
  # one that doesn't exist.
  defp with_join_request(conn, params, request_id, fun) do
    with_group(conn, params, fn group, user ->
      with :ok <- join_request_gate(user, group),
           %GroupJoinRequest{} = request <-
             Groups.get_pending_join_request(group, request_id) || {:error, :not_found} do
        fun.(group, request, user)
      end
    end)
  end

  defp join_request_gate(user, group) do
    case Authorization.authorize(user, :approve_group_members, group) do
      :ok -> :ok
      {:error, :unauthorized} -> {:error, :not_found}
    end
  end

  defp with_group(conn, %{"community_slug" => slug, "group_slug" => group_slug}, fun) do
    user = conn.assigns.current_scope.user

    with %Communities.Community{} = community <- Communities.get_community_by_slug(slug),
         {:ok, group} <- Groups.fetch_viewable_group(user, community, group_slug),
         %Plug.Conn{} = responded <- fun.(group, user) do
      responded
    else
      nil -> ApiError.send(conn, :not_found, "Not found.")
      error -> ApiError.from_result(conn, error)
    end
  end
end
