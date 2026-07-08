defmodule KammerWeb.EventLive.Show do
  @moduledoc """
  Event page (SPEC §6): details, RSVP yes/no/maybe with live counts and
  attendee list, the shared comment engine (ADR 0007), and an ICS
  download for calendars.
  """

  use KammerWeb, :live_view

  import KammerWeb.FeedComponents, only: [relative_time: 1]
  import KammerWeb.KammerComponents

  alias Kammer.Events
  alias Kammer.Feed
  alias KammerWeb.ReportHandlers

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_community={@active_community}
      member_communities={@member_communities}
      member_groups={@member_groups}
      community_relationship={@community_relationship}
      unread_notifications={@unread_notifications}
      current_tab={:events}
    >
      <.header>
        {@event.title}
        <:subtitle>
          <span class="flex flex-wrap items-center gap-x-2">
            <span>{@event.group.name}</span>
            <span :if={@event.location_name}>
              ·
              <%= if @event.location_url do %>
                <a href={@event.location_url} class="link" rel="noopener" target="_blank">
                  {@event.location_name}
                </a>
              <% else %>
                {@event.location_name}
              <% end %>
            </span>
          </span>
        </:subtitle>
        <:actions>
          <.link
            :if={@can_manage? && @event.series_id}
            navigate={~p"/c/#{@active_community.slug}/events/series/#{@event.series_id}"}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-arrow-path" class="size-4" /> {gettext("View series")}
          </.link>
          <a
            href={~p"/c/#{@active_community.slug}/events/#{@event.id}/ics"}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Add to calendar")}
          </a>
          <.button
            :if={@can_manage?}
            phx-click="delete_event"
            data-confirm={gettext("Delete this event?")}
            class="btn btn-ghost btn-sm text-error"
          >
            {gettext("Delete")}
          </.button>
        </:actions>
      </.header>

      <div :if={@event.cancelled_at} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        {gettext("This occurrence was cancelled.")}
      </div>

      <div :if={@event.series_id && !@event.cancelled_at} class="text-sm text-base-content/60">
        <.icon name="hero-arrow-path" class="size-4" />
        {gettext("Part of a recurring series.")}
      </div>

      <div class="rounded-box border border-base-200 p-4">
        <p class="flex items-center gap-2 font-medium">
          <.icon name="hero-calendar-days" class="size-5 text-[var(--accent,#3E6B48)]" />
          {format_when(@event, viewer_timezone(@current_scope, @event))}
        </p>
      </div>

      <div
        :if={@event.description_markdown}
        class="prose prose-sm max-w-none dark:prose-invert"
      >
        {Phoenix.HTML.raw(Kammer.Markdown.to_html(@event.description_markdown))}
      </div>

      <%!-- RSVP --%>
      <section class="rounded-box border border-base-200 p-4">
        <div :if={@can_rsvp?} class="flex flex-wrap gap-2 pb-3">
          <.button
            :for={{status, label} <- rsvp_options()}
            phx-click="rsvp"
            phx-value-status={status}
            class={[
              "btn btn-sm",
              @my_rsvp && @my_rsvp.status == status && "btn-primary",
              !(@my_rsvp && @my_rsvp.status == status) && "btn-outline"
            ]}
          >
            {label}
          </.button>
        </div>
        <div class="flex flex-wrap gap-x-6 gap-y-1 text-sm text-base-content/70">
          <span>
            <span class="font-semibold text-base-content">{count(@event, :yes)}</span> {gettext(
              "going"
            )}
          </span>
          <span>
            <span class="font-semibold text-base-content">{count(@event, :maybe)}</span> {gettext(
              "maybe"
            )}
          </span>
          <span>
            <span class="font-semibold text-base-content">{count(@event, :no)}</span> {gettext(
              "can't make it"
            )}
          </span>
        </div>
        <div :if={going(@event) != []} class="flex flex-wrap items-center gap-1.5 pt-3">
          <.user_avatar
            :for={rsvp <- going(@event)}
            user={rsvp.user}
            size_class="size-7"
            text_class="text-xs"
          />
          <span :if={guest_count(@event, :yes) > 0} class="badge badge-ghost badge-sm">
            {ngettext("+%{count} guest", "+%{count} guests", guest_count(@event, :yes))}
          </span>
        </div>

        <%!-- Guest RSVP (SPEC §6): public events, name + email, no account. --%>
        <div :if={@guest_rsvp_allowed?} class="border-t border-base-200 mt-4 pt-4">
          <p class="pb-2 text-sm font-medium">{gettext("RSVP as a guest")}</p>
          <p class="pb-3 text-sm text-base-content/70">
            {gettext("No account needed — we'll email you a confirmation link.")}
          </p>
          <.form for={@guest_form} id="guest-rsvp-form" phx-submit="guest_rsvp">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-end">
              <.input
                field={@guest_form[:display_name]}
                type="text"
                label={gettext("Name")}
                required
              />
              <.input field={@guest_form[:email]} type="email" label={gettext("Email")} required />
              <.input
                field={@guest_form[:status]}
                type="select"
                label={gettext("Answer")}
                options={rsvp_options() |> Enum.map(fn {status, label} -> {label, status} end)}
              />
              <.button variant="primary" class="btn-sm" phx-disable-with={gettext("Sending...")}>
                {gettext("RSVP")}
              </.button>
            </div>
          </.form>
        </div>
      </section>

      <%!-- Signup slots (issue #37): "bring cake ×2" --%>
      <section
        :if={@event.slots != [] or @can_manage?}
        class="rounded-box border border-base-200 p-4"
      >
        <h2 class="pb-3 text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Signups")}
        </h2>

        <div
          :for={slot <- @event.slots}
          id={"slot-#{slot.id}"}
          class="border-t border-base-200 py-3 first:border-t-0"
        >
          <div class="flex flex-wrap items-center gap-2">
            <p class="font-medium">{slot.title}</p>
            <span class="badge badge-ghost badge-sm">
              {gettext("%{taken} of %{capacity} taken",
                taken: length(slot.claims),
                capacity: slot.capacity
              )}
            </span>
            <span class="ml-auto flex gap-2">
              <.button
                :if={
                  @can_rsvp? and not claimed_by_me?(slot, @current_scope.user) and slot_open?(slot)
                }
                id={"claim-slot-#{slot.id}"}
                phx-click="claim_slot"
                phx-value-slot-id={slot.id}
                class="btn btn-primary btn-sm"
              >
                {gettext("I'll take it")}
              </.button>
              <.button
                :if={@can_rsvp? and claimed_by_me?(slot, @current_scope.user)}
                id={"unclaim-slot-#{slot.id}"}
                phx-click="unclaim_slot"
                phx-value-slot-id={slot.id}
                class="btn btn-outline btn-sm"
              >
                {gettext("Give it up")}
              </.button>
              <button
                :if={@can_manage?}
                phx-click="delete_slot"
                phx-value-slot-id={slot.id}
                data-confirm={gettext("Delete this slot and its signups?")}
                class="btn btn-ghost btn-xs btn-square opacity-40 hover:opacity-100"
                title={gettext("Delete slot")}
              >
                <.icon name="hero-trash" class="size-3.5" />
              </button>
            </span>
          </div>

          <p :if={slot.claims != []} class="pt-1 text-sm text-base-content/70">
            {slot.claims |> Enum.map(&claimant_name/1) |> Enum.join(", ")}
          </p>

          <%!-- Guest claim (same policy + flow as guest RSVP) --%>
          <form
            :if={@guest_rsvp_allowed? and slot_open?(slot)}
            id={"guest-claim-form-#{slot.id}"}
            phx-submit="guest_claim"
            class="flex flex-wrap items-center gap-2 pt-2"
          >
            <input type="hidden" name="slot_id" value={slot.id} />
            <input
              type="text"
              name="guest[display_name]"
              required
              placeholder={gettext("Your name")}
              class="input input-sm flex-1"
            />
            <input
              type="email"
              name="guest[email]"
              required
              placeholder={gettext("Email")}
              class="input input-sm flex-1"
            />
            <button type="submit" class="btn btn-outline btn-sm">
              {gettext("I'll take it")}
            </button>
          </form>
        </div>

        <form
          :if={@can_manage?}
          id="add-slot-form"
          phx-submit="add_slot"
          class="flex flex-wrap items-end gap-2 border-t border-base-200 pt-3"
        >
          <label class="flex flex-1 flex-col gap-1 text-xs text-base-content/60">
            {gettext("What's needed?")}
            <input
              type="text"
              name="slot[title]"
              required
              placeholder={gettext("e.g. Bring cake")}
              class="input input-sm"
            />
          </label>
          <label class="flex w-24 flex-col gap-1 text-xs text-base-content/60">
            {gettext("How many?")}
            <input
              type="number"
              name="slot[capacity]"
              min="1"
              max="1000"
              value="1"
              required
              class="input input-sm"
            />
          </label>
          <button type="submit" class="btn btn-ghost btn-sm">
            <.icon name="hero-plus" class="size-4" /> {gettext("Add slot")}
          </button>
        </form>
      </section>

      <%!-- Comments (same engine as posts) --%>
      <section class="space-y-3">
        <h2 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Comments")}
        </h2>

        <div :for={comment <- top_level_comments(@event)} class="space-y-2">
          <.event_comment
            comment={comment}
            current_user={@current_scope.user}
            can_moderate={@can_manage?}
          />
          <div class="ml-10 space-y-2 border-l border-base-200 pl-3">
            <.event_comment
              :for={reply <- sorted(comment.replies)}
              comment={reply}
              current_user={@current_scope.user}
              can_moderate={@can_manage?}
            />
            <form :if={@can_comment?} phx-submit="create_comment" class="flex items-start gap-2">
              <input type="hidden" name="parent_comment_id" value={comment.id} />
              <textarea
                name="body_markdown"
                rows="1"
                required
                placeholder={gettext("Reply…")}
                class="textarea textarea-xs min-h-8 flex-1"
              ></textarea>
              <button type="submit" class="btn btn-ghost btn-xs">{gettext("Reply")}</button>
            </form>
          </div>
        </div>

        <form :if={@can_comment?} phx-submit="create_comment" class="flex items-start gap-2">
          <textarea
            name="body_markdown"
            rows="1"
            required
            placeholder={gettext("Write a comment…")}
            class="textarea textarea-sm min-h-9 flex-1"
          ></textarea>
          <button type="submit" class="btn btn-primary btn-sm">{gettext("Reply")}</button>
        </form>

        <p
          :if={!@can_comment? and top_level_comments(@event) == []}
          class="text-sm text-base-content/50"
        >
          {gettext("No comments.")}
        </p>
      </section>

      <.report_modal reporting={@reporting} />
    </Layouts.app>
    """
  end

  attr :comment, :map, required: true
  attr :current_user, :map, default: nil
  attr :can_moderate, :boolean, default: false

  defp event_comment(assigns) do
    ~H"""
    <div class="flex items-start gap-2">
      <.user_avatar
        :if={@comment.author_user}
        user={@comment.author_user}
        size_class="size-7"
        text_class="text-xs"
      />
      <div class="min-w-0 flex-1">
        <p class="text-xs text-base-content/60">
          <span class="font-medium text-base-content">
            {(@comment.author_user && @comment.author_user.display_name) || gettext("Deleted user")}
          </span>
          {relative_time(@comment.inserted_at)}
        </p>
        <%= if @comment.deleted_at do %>
          <p class="text-sm italic text-base-content/50">{gettext("This comment was removed.")}</p>
        <% else %>
          <div class="prose prose-sm max-w-none dark:prose-invert">
            {Phoenix.HTML.raw(Kammer.Markdown.to_html(@comment.body_markdown))}
          </div>
        <% end %>
      </div>
      <button
        :if={@current_user && !@comment.deleted_at}
        id={"report-comment-#{@comment.id}"}
        phx-click="start_report"
        phx-value-type="comment"
        phx-value-id={@comment.id}
        class="btn btn-ghost btn-xs btn-square opacity-40 hover:opacity-100"
        title={gettext("Report")}
      >
        <.icon name="hero-flag" class="size-3.5" />
      </button>
      <button
        :if={
          @current_user &&
            (@can_moderate or (@current_user.id == @comment.author_user_id && !@comment.deleted_at))
        }
        phx-click="delete_comment"
        phx-value-id={@comment.id}
        data-confirm={gettext("Remove this comment?")}
        class="btn btn-ghost btn-xs btn-square opacity-40 hover:opacity-100"
      >
        <.icon name="hero-trash" class="size-3.5" />
      </button>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"event_id" => event_id}, _session, socket) do
    current_user = current_user(socket.assigns)
    community = socket.assigns.active_community

    client_ip =
      case get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _no_peer_data -> nil
      end

    socket = socket |> assign(:client_ip, client_ip) |> assign(:reporting, nil)

    case Events.fetch_viewable_event(current_user, community, event_id) do
      {:ok, event} ->
        {:ok, socket |> assign(:event_id, event.id) |> load_event(event)}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Event not found."))
         |> push_navigate(to: not_found_path(current_user, community))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("rsvp", %{"status" => status}, socket) do
    current_user = socket.assigns.current_scope.user
    status_atom = String.to_existing_atom(status)

    case Events.rsvp(current_user, socket.assigns.event, status_atom) do
      {:ok, _rsvp} ->
        {:noreply, reload(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("create_comment", params, socket) do
    current_user = socket.assigns.current_scope.user

    case Events.create_comment(current_user, socket.assigns.event, params) do
      {:ok, _comment} ->
        {:noreply, reload(socket)}

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many attempts. Please try again later."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("delete_comment", %{"id" => comment_id}, socket) do
    current_user = socket.assigns.current_scope.user

    with %Kammer.Feed.Comment{} = comment <- Feed.get_comment(comment_id),
         {:ok, _deleted} <- Feed.delete_comment(current_user, comment) do
      {:noreply, reload(socket)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event(report_event, params, socket)
      when report_event in ~w(start_report cancel_report submit_report) do
    ReportHandlers.handle(report_event, params, socket)
  end

  def handle_event("guest_rsvp", %{"guest" => guest_params}, socket) do
    event = socket.assigns.event

    result =
      Events.request_guest_rsvp(event, event.group, guest_params,
        client_ip: socket.assigns.client_ip,
        confirm_url_fun: fn token -> url(~p"/guest/rsvp/confirm/#{token}") end
      )

    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(:guest_form, to_form(%{}, as: "guest"))
         |> put_flash(
           :info,
           gettext("Almost there — follow the link we just emailed you to confirm your RSVP.")
         )}

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many attempts. Please try again later."))}

      {:error, %Ecto.Changeset{} = _changeset} ->
        {:noreply,
         socket
         |> assign(:guest_form, to_form(guest_params, as: "guest"))
         |> put_flash(:error, gettext("Please check your name and email address."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("add_slot", %{"slot" => slot_params}, socket) do
    current_user = socket.assigns.current_scope.user

    case Events.create_slot(current_user, socket.assigns.event, slot_params) do
      {:ok, _slot} ->
        {:noreply, reload(socket)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("Please give the slot a title."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("delete_slot", %{"slot-id" => slot_id}, socket) do
    current_user = socket.assigns.current_scope.user

    with %Kammer.Events.EventSlot{} = slot <- Events.get_slot(slot_id),
         {:ok, _slot} <- Events.delete_slot(current_user, slot) do
      {:noreply, reload(socket)}
    else
      _error -> {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("claim_slot", %{"slot-id" => slot_id}, socket) do
    current_user = socket.assigns.current_scope.user

    with %Kammer.Events.EventSlot{} = slot <- Events.get_slot(slot_id),
         {:ok, _claim} <- Events.claim_slot(current_user, slot) do
      {:noreply, reload(socket)}
    else
      {:error, :slot_full} ->
        {:noreply, socket |> put_flash(:error, gettext("That slot just filled up.")) |> reload()}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("unclaim_slot", %{"slot-id" => slot_id}, socket) do
    current_user = socket.assigns.current_scope.user

    claim =
      Events.get_slot_claim(slot_id, current_user.id)

    with %Kammer.Events.SlotClaim{} <- claim,
         {:ok, _claim} <- Events.unclaim_slot(current_user, claim) do
      {:noreply, reload(socket)}
    else
      _error -> {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("guest_claim", %{"slot_id" => slot_id, "guest" => guest_params}, socket) do
    event = socket.assigns.event

    with %Kammer.Events.EventSlot{} = slot <- Events.get_slot(slot_id),
         :ok <-
           Events.request_guest_claim(slot, event, event.group, guest_params,
             client_ip: socket.assigns.client_ip,
             confirm_url_fun: fn token -> url(~p"/guest/claim/confirm/#{token}") end
           ) do
      {:noreply,
       put_flash(
         socket,
         :info,
         gettext("Almost there — follow the link we just emailed you to confirm your signup.")
       )}
    else
      {:error, :slot_full} ->
        {:noreply, socket |> put_flash(:error, gettext("That slot just filled up.")) |> reload()}

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many attempts. Please try again later."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(socket, :error, gettext("Please check your name and email address."))}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("delete_event", _params, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    case Events.delete_event(current_user, socket.assigns.event) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Event deleted."))
         |> push_navigate(to: ~p"/c/#{community.slug}/events")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  defp reload(socket) do
    current_user = current_user(socket.assigns)
    community = socket.assigns.active_community

    case Events.fetch_viewable_event(current_user, community, socket.assigns.event_id) do
      {:ok, event} -> load_event(socket, event)
      {:error, _reason} -> socket
    end
  end

  defp load_event(socket, event) do
    current_user = current_user(socket.assigns)
    group = event.group
    relationship = Kammer.Authorization.relationship(current_user, group)

    socket
    |> assign(:event, event)
    |> assign(:my_rsvp, Events.get_rsvp(event, current_user))
    |> assign(:can_rsvp?, Kammer.Authorization.can_react?(current_user, group, relationship))
    |> assign(
      :guest_rsvp_allowed?,
      is_nil(current_user) and Kammer.Authorization.can_guest_rsvp?(group)
    )
    |> assign(:guest_form, to_form(%{}, as: "guest"))
    |> assign(
      :can_comment?,
      Kammer.Authorization.can?(current_user, :comment_in_group, group, relationship) and
        is_nil(event.comment_locked_at)
    )
    |> assign(:can_manage?, Events.can_manage_event?(current_user, event, group))
  end

  defp current_user(%{current_scope: %{user: user}}), do: user
  defp current_user(_assigns), do: nil

  defp not_found_path(nil, community), do: ~p"/c/#{community.slug}"
  defp not_found_path(_user, community), do: ~p"/c/#{community.slug}/events"

  defp viewer_timezone(%{user: %{timezone: timezone}}, _event), do: timezone
  defp viewer_timezone(_scope, event), do: event.timezone

  defp guest_count(event, status) do
    Enum.count(event.rsvps, fn rsvp -> rsvp.status == status and rsvp.guest_identity_id end)
  end

  defp rsvp_options do
    [
      {"yes", gettext("I'm going")},
      {"maybe", gettext("Maybe")},
      {"no", gettext("Can't make it")}
    ]
  end

  defp count(event, status), do: Enum.count(event.rsvps, fn rsvp -> rsvp.status == status end)

  defp slot_open?(slot), do: length(slot.claims) < slot.capacity

  defp claimed_by_me?(_slot, nil), do: false
  defp claimed_by_me?(slot, user), do: Enum.any?(slot.claims, &(&1.user_id == user.id))

  defp claimant_name(%{user: %{display_name: name}}) when is_binary(name), do: name

  defp claimant_name(%{guest_identity: %{display_name: name}}) when is_binary(name),
    do: gettext("%{name} (guest)", name: name)

  defp claimant_name(_claim), do: gettext("Deleted user")

  defp going(event) do
    event.rsvps
    |> Enum.filter(fn rsvp -> rsvp.status == :yes and rsvp.user end)
    |> Enum.sort_by(& &1.inserted_at, DateTime)
  end

  defp top_level_comments(event) do
    event.comments
    |> Enum.filter(&is_nil(&1.parent_comment_id))
    |> Enum.sort_by(& &1.inserted_at, DateTime)
  end

  defp sorted(comments), do: Enum.sort_by(comments, & &1.inserted_at, DateTime)

  defp format_when(event, timezone) do
    starts = shift(event.starts_at, timezone)

    cond do
      event.all_day and event.ends_at ->
        "#{Calendar.strftime(starts, "%a %d %b %Y")} – #{Calendar.strftime(shift(event.ends_at, timezone), "%a %d %b %Y")}"

      event.all_day ->
        "#{Calendar.strftime(starts, "%a %d %b %Y")} · #{gettext("All day")}"

      event.ends_at ->
        ends = shift(event.ends_at, timezone)

        if DateTime.to_date(starts) == DateTime.to_date(ends) do
          "#{Calendar.strftime(starts, "%a %d %b %Y · %H:%M")}–#{Calendar.strftime(ends, "%H:%M")}"
        else
          "#{Calendar.strftime(starts, "%a %d %b %Y %H:%M")} – #{Calendar.strftime(ends, "%a %d %b %Y %H:%M")}"
        end

      true ->
        Calendar.strftime(starts, "%a %d %b %Y · %H:%M")
    end
  end

  defp shift(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> datetime
    end
  end
end
