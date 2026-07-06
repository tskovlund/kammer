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

      <div class="rounded-box border border-base-200 p-4">
        <p class="flex items-center gap-2 font-medium">
          <.icon name="hero-calendar-days" class="size-5 text-[var(--accent,#3E6B48)]" />
          {format_when(@event, @current_scope.user.timezone)}
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
        </div>
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
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    case Events.fetch_viewable_event(current_user, community, event_id) do
      {:ok, event} ->
        {:ok, socket |> assign(:event_id, event.id) |> load_event(event)}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Event not found."))
         |> push_navigate(to: ~p"/c/#{community.slug}/events")}
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

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("delete_comment", %{"id" => comment_id}, socket) do
    current_user = socket.assigns.current_scope.user

    with %Kammer.Feed.Comment{} = comment <- Kammer.Repo.get(Kammer.Feed.Comment, comment_id),
         {:ok, _deleted} <- Feed.delete_comment(current_user, comment) do
      {:noreply, reload(socket)}
    else
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
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    case Events.fetch_viewable_event(current_user, community, socket.assigns.event_id) do
      {:ok, event} -> load_event(socket, event)
      {:error, _reason} -> socket
    end
  end

  defp load_event(socket, event) do
    current_user = socket.assigns.current_scope.user
    group = event.group
    relationship = Kammer.Authorization.relationship(current_user, group)

    socket
    |> assign(:event, event)
    |> assign(:my_rsvp, Events.get_rsvp(event, current_user))
    |> assign(:can_rsvp?, Kammer.Authorization.can_react?(current_user, group, relationship))
    |> assign(
      :can_comment?,
      Kammer.Authorization.can?(current_user, :comment_in_group, group, relationship) and
        is_nil(event.comment_locked_at)
    )
    |> assign(:can_manage?, Events.can_manage_event?(current_user, event, group))
  end

  defp rsvp_options do
    [
      {"yes", gettext("I'm going")},
      {"maybe", gettext("Maybe")},
      {"no", gettext("Can't make it")}
    ]
  end

  defp count(event, status), do: Enum.count(event.rsvps, fn rsvp -> rsvp.status == status end)

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
