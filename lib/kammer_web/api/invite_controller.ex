defmodule KammerWeb.Api.InviteController do
  @moduledoc """
  Invite links over the API (SPEC §3, issue #182): admins issue, list,
  and revoke community- and group-scoped invites; anyone holding a
  token previews what it opens; a signed-in invitee accepts — joining
  the community (and group, for group invites) and learning which
  required custom profile fields (ADR 0020) still need answers, the
  API twin of the `/invite/:token` → complete-profile web flow.

  No-oracle: invites are visible only to callers who may create them,
  so revoking one the caller may not manage answers 404, exactly like
  one that doesn't exist. Preview and accept treat a revoked, expired,
  used-up, unknown, or ban-refused token as one neutral "no longer
  valid", mirroring the web landing page.
  """

  use KammerWeb, :controller

  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Communities.Community
  alias Kammer.Invitations
  alias Kammer.Invitations.Invite
  alias KammerWeb.Api.GroupGate
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  # The invite fields a caller may set; community_id/group_id/creator
  # are never cast from the request — the context sets them.
  @invite_fields ~w(invited_email expires_at max_uses)

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"community_slug" => slug, "group_slug" => group_slug}) do
    with_group(conn, slug, group_slug, fn group, user ->
      with {:ok, invites} <- Invitations.list_invites(user, group) do
        json(conn, %{data: Enum.map(invites, &Serializer.invite/1)})
      end
    end)
  end

  def index(conn, %{"community_slug" => slug}) do
    with_community(conn, slug, fn community, user ->
      with {:ok, invites} <- Invitations.list_invites(user, community) do
        json(conn, %{data: Enum.map(invites, &Serializer.invite/1)})
      end
    end)
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"community_slug" => slug, "group_slug" => group_slug} = params) do
    with_group(conn, slug, group_slug, fn group, user ->
      with {:ok, invite} <-
             Invitations.create_group_invite(user, group, Map.take(params, @invite_fields)) do
        conn |> put_status(201) |> json(%{data: Serializer.invite(invite)})
      end
    end)
  end

  def create(conn, %{"community_slug" => slug} = params) do
    with_community(conn, slug, fn community, user ->
      with {:ok, invite} <-
             Invitations.create_community_invite(
               user,
               community,
               Map.take(params, @invite_fields)
             ) do
        conn |> put_status(201) |> json(%{data: Serializer.invite(invite)})
      end
    end)
  end

  @spec revoke(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def revoke(conn, %{"community_slug" => slug, "invite_id" => invite_id}) do
    with_community(conn, slug, fn community, user ->
      invite = Invitations.get_invite(invite_id)

      # An invite the caller may not manage answers 404 — invite
      # existence is only ever shown to those who can list them, so a
      # denied revoke must be indistinguishable from a missing id.
      with %Invite{community_id: community_id} when community_id == community.id <-
             invite || {:error, :not_found},
           {:ok, revoked} <- hide_denials(Invitations.revoke_invite(user, invite)) do
        json(conn, %{data: Serializer.invite(revoked)})
      else
        %Invite{} -> {:error, :not_found}
        error -> error
      end
    end)
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"token" => token}) do
    case Invitations.get_invite_by_token(token) do
      %Invite{} = invite ->
        if Invite.redeemable?(invite, DateTime.utc_now(:second)) do
          json(conn, %{data: Serializer.invite_preview(invite)})
        else
          invalid_invite(conn)
        end

      nil ->
        invalid_invite(conn)
    end
  end

  @spec accept(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def accept(conn, %{"token" => token}) do
    user = conn.assigns.current_scope.user

    case Invitations.redeem_invite(user, token) do
      {:ok, invite} ->
        json(conn, %{data: accept_payload(invite, user)})

      {:error, :email_mismatch} ->
        ApiError.send(
          conn,
          :forbidden,
          "This invitation was sent to a different email address."
        )

      # Revoked, expired, used up, unknown, or refused by a ban — one
      # neutral answer, mirroring the web landing page.
      {:error, _reason} ->
        invalid_invite(conn)
    end
  end

  # The accepted target plus the required custom fields still missing —
  # the client collects those next (PUT the community profile), the API
  # sibling of the complete-profile redirect.
  defp accept_payload(%Invite{community: community} = invite, user) do
    missing = Communities.missing_required_custom_fields(community, user)

    %{
      community:
        Serializer.community(community, user, Authorization.relationship(user, community)),
      group:
        invite.group &&
          Serializer.group(invite.group, user, Authorization.relationship(user, invite.group)),
      missing_required_fields: Enum.map(missing, &Serializer.custom_field/1)
    }
  end

  defp invalid_invite(conn),
    do: ApiError.send(conn, :not_found, "This invitation is no longer valid.")

  defp hide_denials({:error, :unauthorized}), do: {:error, :not_found}
  defp hide_denials(other), do: other

  defp with_community(conn, slug, fun) do
    user = conn.assigns.current_scope.user

    with %Community{} = community <- Communities.get_community_by_slug(slug),
         %Plug.Conn{} = responded <- fun.(community, user) do
      responded
    else
      nil -> ApiError.send(conn, :not_found, "Not found.")
      error -> ApiError.from_result(conn, error)
    end
  end

  # No-oracle (#339): a missing community, a missing group, and a group
  # the caller may not even *view* all fold into the same 404 via
  # `GroupGate.fetch/3`; a group member without invite rights in a
  # visible group still gets the context's honest 403.
  defp with_group(conn, community_slug, group_slug, fun) do
    user = conn.assigns.current_scope.user

    with {:ok, _community, group} <- GroupGate.fetch(user, community_slug, group_slug),
         %Plug.Conn{} = responded <- fun.(group, user) do
      responded
    else
      {:error, :not_found} -> ApiError.send(conn, :not_found, "Not found.")
      error -> ApiError.from_result(conn, error)
    end
  end
end
