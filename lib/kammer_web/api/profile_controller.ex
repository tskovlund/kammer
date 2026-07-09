defmodule KammerWeb.Api.ProfileController do
  @moduledoc """
  The caller's own account over the API (SPEC §4, issue #182): base
  profile read/update (display name, locale, timezone, digests, bio,
  pronouns, contact fields with their visibilities), the per-community
  custom-field answers (ADR 0020) with the missing-required nag the
  web's complete-profile page reads, and device management (issue
  #174) — listing every revocable credential (browser sessions and API
  device tokens) and revoking any by id.

  Everything here is owner-scoped by construction: the contexts only
  ever read or write rows keyed to the authenticated user, so there is
  no cross-user surface to oracle-proof — a foreign device id is
  simply not found.
  """

  use KammerWeb, :controller

  alias Kammer.Accounts
  alias Kammer.Accounts.UserToken
  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Communities.Community
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiAuth
  alias KammerWeb.ApiError

  # The profile fields a caller may set; email changes stay on the web
  # flow (they require a confirmation email round-trip), and
  # instance_operator is never cast from any request.
  @profile_fields ~w(display_name locale timezone digest_frequency feed_sort bio pronouns
                     contact_phone contact_phone_visibility contact_email
                     contact_email_visibility contact_note contact_note_visibility)

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    json(conn, %{data: Serializer.profile(conn.assigns.current_scope.user)})
  end

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, params) do
    user = conn.assigns.current_scope.user

    case Accounts.update_user_settings(user, Map.take(params, @profile_fields)) do
      {:ok, updated} -> json(conn, %{data: Serializer.profile(updated)})
      error -> ApiError.from_result(conn, error)
    end
  end

  @spec community_profile(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def community_profile(conn, %{"community_slug" => slug}) do
    with_member_community(conn, slug, fn community, user ->
      json(conn, %{data: community_profile_payload(community, user)})
    end)
  end

  @spec update_community_profile(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_community_profile(conn, %{"community_slug" => slug} = params) do
    with_member_community(conn, slug, fn community, user ->
      :ok = Communities.put_custom_field_values(user, community, field_values(params))
      json(conn, %{data: community_profile_payload(community, user)})
    end)
  end

  @spec devices(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def devices(conn, _params) do
    user = conn.assigns.current_scope.user
    current_id = current_device_id(conn)

    json(conn, %{
      data: user |> Accounts.list_user_devices() |> Enum.map(&Serializer.device(&1, current_id))
    })
  end

  @spec revoke_device(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def revoke_device(conn, %{"device_id" => device_id}) do
    user = conn.assigns.current_scope.user

    case Accounts.revoke_user_device(user, device_id) do
      {:ok, %UserToken{context: "api-device"}} ->
        # Sever live sockets too (issue #174) — deleting the token row
        # alone would leave an already-open websocket streaming. Same
        # broadcast the self-revoke endpoint sends; the socket id is per
        # user, so sibling devices just reconnect with their still-valid
        # tokens.
        KammerWeb.Endpoint.broadcast("api_user_socket:#{user.id}", "disconnect", %{})
        json(conn, %{status: "revoked"})

      {:ok, %UserToken{}} ->
        json(conn, %{status: "revoked"})

      {:error, :not_found} = error ->
        ApiError.from_result(conn, error)
    end
  end

  ## Internals

  # Own custom-field answers are member business: a non-member has no
  # profile in the community, so these answer an honest 403 — the
  # community's existence is public (its slug serves public pages).
  defp with_member_community(conn, slug, fun) do
    user = conn.assigns.current_scope.user

    with %Community{} = community <- Communities.get_community_by_slug(slug),
         :ok <- Authorization.authorize(user, :view_community, community),
         %Plug.Conn{} = responded <- fun.(community, user) do
      responded
    else
      nil -> ApiError.send(conn, :not_found, "Not found.")
      error -> ApiError.from_result(conn, error)
    end
  end

  # The member sees and answers every field the community defines —
  # including admins-visible ones (it's their own answer, e.g. dietary
  # needs shown only to organizers); visibility redacts the roster, not
  # the owner's form.
  defp community_profile_payload(community, user) do
    %{
      fields:
        community |> Communities.list_custom_fields() |> Enum.map(&Serializer.custom_field/1),
      values: Communities.get_custom_field_values(community, user),
      missing_required_field_ids:
        community
        |> Communities.missing_required_custom_fields(user)
        |> Enum.map(& &1.id)
    }
  end

  # Only string answers pass through — the context trims, clears on
  # blank, and ignores fields outside the community.
  defp field_values(%{"values" => %{} = values}) do
    values |> Enum.filter(fn {_field_id, value} -> is_binary(value) end) |> Map.new()
  end

  defp field_values(_params), do: %{}

  defp current_device_id(conn) do
    with token when is_binary(token) <- ApiAuth.bearer_token(conn),
         %UserToken{id: id} <- Accounts.get_device_token(token) do
      id
    else
      _missing -> nil
    end
  end
end
