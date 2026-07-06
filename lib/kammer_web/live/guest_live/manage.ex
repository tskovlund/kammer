defmodule KammerWeb.GuestLive.Manage do
  @moduledoc """
  A guest's management page (SPEC §6/§12), reached only through the
  signed link in their confirmation emails: every RSVP they gave (with
  the answer changeable), every comment they wrote (with its moderation
  state), and one button that erases all of it. The token in the URL is
  the entire credential.
  """

  use KammerWeb, :live_view

  alias Kammer.Events
  alias Kammer.Feed.Comment
  alias Kammer.Guests

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-lg space-y-6">
        <.header>
          {gettext("Your guest data")}
          <:subtitle>
            {gettext("Everything this instance stores about you, %{name}",
              name: @identity.display_name
            )}
          </:subtitle>
        </.header>

        <section :if={@rsvps != []} class="rounded-box border border-base-200 p-4">
          <h2 class="pb-3 text-sm font-medium uppercase tracking-wide text-base-content/50">
            {gettext("Your RSVPs")}
          </h2>
          <div :for={rsvp <- @rsvps} class="border-t border-base-200 py-3 first:border-t-0">
            <p class="pb-2 font-medium">{rsvp.event.title}</p>
            <div class="flex flex-wrap gap-2">
              <.button
                :for={{status, label} <- rsvp_options()}
                phx-click="set_status"
                phx-value-event-id={rsvp.event_id}
                phx-value-status={status}
                class={[
                  "btn btn-sm",
                  to_string(rsvp.status) == status && "btn-primary",
                  to_string(rsvp.status) != status && "btn-outline"
                ]}
              >
                {label}
              </.button>
            </div>
          </div>
        </section>

        <section :if={@comments != []} class="rounded-box border border-base-200 p-4">
          <h2 class="pb-3 text-sm font-medium uppercase tracking-wide text-base-content/50">
            {gettext("Your comments")}
          </h2>
          <div :for={comment <- @comments} class="border-t border-base-200 py-3 first:border-t-0">
            <p class="pb-1 text-xs text-base-content/60">
              {comment.post.group.name}
              <span :if={comment.pending_approval} class="badge badge-warning badge-xs align-middle">
                {gettext("Awaiting approval")}
              </span>
              <span :if={Comment.deleted?(comment)} class="badge badge-ghost badge-xs align-middle">
                {gettext("Removed")}
              </span>
            </p>
            <p class="whitespace-pre-wrap text-sm">{comment.body_markdown}</p>
          </div>
        </section>

        <section class="rounded-box border border-base-200 p-4">
          <p class="pb-3 text-sm text-base-content/70">
            {gettext(
              "We store your name, email address, and what you see above — nothing else. Erasing removes all of it immediately."
            )}
          </p>
          <.button
            id="guest-erase"
            phx-click="erase"
            data-confirm={gettext("Erase your data? This cannot be undone.")}
            class="btn btn-sm btn-outline text-error"
          >
            {gettext("Erase my data")}
          </.button>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"token" => token}, _session, socket) do
    case Guests.fetch_manage_state(token) do
      {:ok, state} ->
        {:ok,
         socket
         |> assign(:token, token)
         |> assign(:identity, state.identity)
         |> assign(:rsvps, state.rsvps)
         |> assign(:comments, state.comments)}

      {:error, :invalid} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That link is invalid or has expired."))
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("set_status", %{"event-id" => event_id, "status" => status}, socket) do
    status_atom = String.to_existing_atom(status)

    case Events.update_guest_rsvp(socket.assigns.token, event_id, status_atom) do
      {:ok, _rsvp} ->
        {:noreply,
         socket
         |> reload_state()
         |> put_flash(:info, gettext("Your answer is updated."))}

      {:error, :invalid} ->
        {:noreply, put_flash(socket, :error, gettext("That link is invalid or has expired."))}
    end
  end

  def handle_event("erase", _params, socket) do
    case Guests.erase_by_token(socket.assigns.token) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Your data has been erased."))
         |> push_navigate(to: ~p"/")}

      {:error, :invalid} ->
        {:noreply, put_flash(socket, :error, gettext("That link is invalid or has expired."))}
    end
  end

  defp reload_state(socket) do
    case Guests.fetch_manage_state(socket.assigns.token) do
      {:ok, state} ->
        socket
        |> assign(:rsvps, state.rsvps)
        |> assign(:comments, state.comments)

      {:error, :invalid} ->
        socket
    end
  end

  defp rsvp_options do
    [
      {"yes", gettext("I'm going")},
      {"maybe", gettext("Maybe")},
      {"no", gettext("Can't make it")}
    ]
  end
end
