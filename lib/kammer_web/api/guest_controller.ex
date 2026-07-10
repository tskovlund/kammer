defmodule KammerWeb.Api.GuestController do
  @moduledoc """
  Account-less guest surfaces over the API (issue #185, ADR 0024):
  RSVP, signup-slot claim, and comment via signed links, plus the
  unified management page — the API twin of the `GuestRsvpController`/
  `GuestClaimController`/`GuestCommentController` landings and
  `GuestLive.Manage`, over JSON instead of redirects.

  These are public and tokenless by design (ADR 0024): guests hold no
  device token. The signed link in the URL is the whole credential
  (ADR 0013) — a *confirm* link proves control of the email, a
  *management* link authorizes changing or erasing exactly one guest's
  records. So these routes live in the plain `:api` pipeline, never
  `:api_authenticated`.

  Every request runs the same context function, authorization, and
  rate limit the LiveView flows use — the controller adds transport,
  never policy. An invalid, expired, or used token is answered with one
  neutral "no longer valid" (never an oracle), mirroring the web dead
  ends and the invite precedent.
  """

  use KammerWeb, :controller

  alias Kammer.Communities
  alias Kammer.Communities.Community
  alias Kammer.Events
  alias Kammer.Events.EventSlot
  alias Kammer.Feed
  alias Kammer.Feed.Post
  alias Kammer.Groups
  alias Kammer.Guests
  alias Kammer.Newsletters
  alias KammerWeb.Api.PublicLinks
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @guest_fields ~w(email display_name)
  @statuses %{"yes" => :yes, "no" => :no, "maybe" => :maybe}
  @cadences %{"per_post" => :per_post, "daily" => :daily, "weekly" => :weekly}

  ## RSVP (SPEC §6)

  @spec request_rsvp(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request_rsvp(conn, %{"community_slug" => slug, "event_id" => event_id} = params) do
    with_viewable_event(conn, slug, event_id, fn event ->
      attrs = Map.take(params, @guest_fields ++ ["status"])

      case Events.request_guest_rsvp(event, event.group, attrs,
             client_ip: conn.remote_ip,
             confirm_url_fun: &PublicLinks.confirm_url(conn, :rsvp, &1)
           ) do
        :ok -> confirmation_sent(conn)
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec confirm_rsvp(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm_rsvp(conn, %{"token" => token}) when is_binary(token) do
    case Events.confirm_guest_rsvp(token, &PublicLinks.manage_url(conn, &1)) do
      {:ok, event, identity} ->
        confirmed(conn, identity.display_name, PublicLinks.event_path(event))

      {:error, :invalid} ->
        invalid_link(conn)
    end
  end

  def confirm_rsvp(conn, _params), do: token_required(conn)

  ## Signup-slot claim (issue #37)

  @spec request_claim(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request_claim(
        conn,
        %{"community_slug" => slug, "event_id" => event_id, "slot_id" => slot_id} = params
      ) do
    with_viewable_event(conn, slug, event_id, fn event ->
      # A missing slot is a neutral 404; a slot that belongs to another
      # event is refused by the context's own event-membership check.
      with %EventSlot{} = slot <- Events.get_slot(slot_id) || :gone,
           :ok <-
             Events.request_guest_claim(slot, event, event.group, Map.take(params, @guest_fields),
               client_ip: conn.remote_ip,
               confirm_url_fun: &PublicLinks.confirm_url(conn, :claim, &1)
             ) do
        confirmation_sent(conn)
      else
        :gone -> ApiError.send(conn, :not_found, "Not found.")
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec confirm_claim(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm_claim(conn, %{"token" => token}) when is_binary(token) do
    case Events.confirm_guest_claim(token, &PublicLinks.manage_url(conn, &1)) do
      {:ok, event, identity} ->
        confirmed(conn, identity.display_name, PublicLinks.event_path(event))

      {:error, :slot_full} ->
        ApiError.send(conn, :slot_full, "This signup slot is full.")

      {:error, :invalid} ->
        invalid_link(conn)
    end
  end

  def confirm_claim(conn, _params), do: token_required(conn)

  ## Comments (SPEC §3 `members_and_guests`)

  @spec request_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request_comment(
        conn,
        %{"community_slug" => slug, "group_slug" => group_slug, "post_id" => post_id} = params
      ) do
    with_viewable_group(conn, slug, group_slug, fn group ->
      attrs = Map.take(params, @guest_fields ++ ["body_markdown"])

      # A post that isn't in this group is refused by `guest_comment_open?`
      # itself — the same neutral 403 as any closed comment surface.
      with %Post{} = post <- Feed.get_post(post_id) || :gone,
           :ok <-
             Feed.request_guest_comment(post, group, attrs,
               client_ip: conn.remote_ip,
               confirm_url_fun: &PublicLinks.confirm_url(conn, :comment, &1)
             ) do
        confirmation_sent(conn)
      else
        :gone -> ApiError.send(conn, :not_found, "Not found.")
        error -> ApiError.from_result(conn, error)
      end
    end)
  end

  @spec confirm_comment(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm_comment(conn, %{"token" => token}) when is_binary(token) do
    case Feed.confirm_guest_comment(token, &PublicLinks.manage_url(conn, &1)) do
      {:ok, post, identity} ->
        confirmed(
          conn,
          identity.display_name,
          PublicLinks.community_group_path(post.community, post.group)
        )

      {:error, :invalid} ->
        invalid_link(conn)
    end
  end

  def confirm_comment(conn, _params), do: token_required(conn)

  ## Management page (SPEC §6/§8/§12) — the management token is the credential

  @spec manage(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def manage(conn, %{"token" => token}) do
    case Guests.fetch_manage_state(token) do
      {:ok, state} -> json(conn, %{data: Serializer.guest_manage_state(state)})
      {:error, :invalid} -> invalid_link(conn)
    end
  end

  @spec set_rsvp(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def set_rsvp(conn, %{"token" => token, "event_id" => event_id, "status" => status}) do
    case Map.fetch(@statuses, status) do
      {:ok, status_atom} ->
        with_updated_state(conn, token, Events.update_guest_rsvp(token, event_id, status_atom))

      :error ->
        ApiError.send(conn, :bad_request, "status must be one of yes, no, maybe.")
    end
  end

  @spec release_claim(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def release_claim(conn, %{"token" => token, "claim_id" => claim_id}) do
    with_updated_state(conn, token, Events.unclaim_slot_by_token(token, claim_id))
  end

  @spec set_cadence(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def set_cadence(conn, %{"token" => token, "subscription_id" => id, "cadence" => cadence}) do
    case Map.fetch(@cadences, cadence) do
      {:ok, cadence_atom} ->
        with_updated_state(conn, token, Newsletters.update_cadence(token, id, cadence_atom))

      :error ->
        ApiError.send(conn, :bad_request, "cadence must be one of per_post, daily, weekly.")
    end
  end

  @spec unsubscribe(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unsubscribe(conn, %{"token" => token, "subscription_id" => id}) do
    with_updated_state(conn, token, Newsletters.unsubscribe_by_token(token, id))
  end

  @spec erase(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def erase(conn, %{"token" => token}) do
    case Guests.erase_by_token(token) do
      :ok -> json(conn, %{status: "erased"})
      {:error, :invalid} -> invalid_link(conn)
    end
  end

  ## Shared transport

  # After a management mutation, answer with the refreshed inventory —
  # the API twin of the web page's re-render. A token that no longer
  # verifies (or a record that isn't this guest's) is one neutral
  # answer, never an oracle.
  defp with_updated_state(conn, token, result) do
    case result do
      {:ok, _record} -> refreshed_state(conn, token)
      :ok -> refreshed_state(conn, token)
      {:error, :invalid} -> invalid_link(conn)
    end
  end

  defp refreshed_state(conn, token) do
    case Guests.fetch_manage_state(token) do
      {:ok, state} -> json(conn, %{data: Serializer.guest_manage_state(state)})
      {:error, :invalid} -> invalid_link(conn)
    end
  end

  defp with_viewable_event(conn, slug, event_id, fun) do
    with %Community{} = community <- Communities.get_community_by_slug(slug) || :gone,
         {:ok, event} <- Events.fetch_viewable_event(nil, community, event_id) do
      fun.(event)
    else
      :gone -> ApiError.send(conn, :not_found, "Not found.")
      error -> ApiError.from_result(conn, error)
    end
  end

  defp with_viewable_group(conn, slug, group_slug, fun) do
    with %Community{} = community <- Communities.get_community_by_slug(slug) || :gone,
         {:ok, group} <- Groups.fetch_viewable_group(nil, community, group_slug) do
      fun.(group)
    else
      :gone -> ApiError.send(conn, :not_found, "Not found.")
      error -> ApiError.from_result(conn, error)
    end
  end

  defp confirmation_sent(conn),
    do: conn |> put_status(202) |> json(%{status: "confirmation_sent"})

  defp confirmed(conn, guest_name, redirect_path),
    do: json(conn, %{data: %{guest_name: guest_name, redirect_path: redirect_path}})

  defp invalid_link(conn),
    do: ApiError.send(conn, :not_found, "This link is no longer valid.")

  defp token_required(conn),
    do: ApiError.send(conn, :bad_request, "A token is required.")
end
