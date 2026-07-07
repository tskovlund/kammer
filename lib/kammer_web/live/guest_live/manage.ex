defmodule KammerWeb.GuestLive.Manage do
  @moduledoc """
  A guest's management page (SPEC §6/§8/§12), reached only through the
  signed link in their confirmation emails: every RSVP they gave (with
  the answer changeable), every comment they wrote (with its moderation
  state), every newsletter subscription (cadence changeable,
  unsubscribable), and one button that erases all of it. The token in
  the URL is the entire credential.
  """

  use KammerWeb, :live_view

  alias Kammer.Events
  alias Kammer.Feed.Comment
  alias Kammer.Guests
  alias Kammer.Newsletters
  alias Kammer.Newsletters.NewsletterSubscription

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

        <section :if={@claims != []} class="rounded-box border border-base-200 p-4">
          <h2 class="pb-3 text-sm font-medium uppercase tracking-wide text-base-content/50">
            {gettext("Your signups")}
          </h2>
          <div
            :for={claim <- @claims}
            class="flex items-center gap-3 border-t border-base-200 py-3 first:border-t-0"
          >
            <div class="min-w-0 flex-1">
              <p class="font-medium">{claim.slot.title}</p>
              <p class="text-xs text-base-content/60">{claim.slot.event.title}</p>
            </div>
            <.button
              id={"release-claim-#{claim.id}"}
              phx-click="release_claim"
              phx-value-claim-id={claim.id}
              data-confirm={gettext("Give up this signup?")}
              class="btn btn-sm btn-outline"
            >
              {gettext("Give it up")}
            </.button>
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

        <section :if={@subscriptions != []} class="rounded-box border border-base-200 p-4">
          <h2 class="pb-3 text-sm font-medium uppercase tracking-wide text-base-content/50">
            {gettext("Your newsletter subscriptions")}
          </h2>
          <div
            :for={subscription <- @subscriptions}
            class="flex flex-wrap items-center gap-2 border-t border-base-200 py-3 first:border-t-0"
          >
            <div class="min-w-0 flex-1">
              <p class="font-medium">
                {subscription.group.community.name} / {subscription.group.name}
              </p>
            </div>
            <form id={"cadence-#{subscription.id}"} phx-change="change_cadence">
              <input type="hidden" name="subscription_id" value={subscription.id} />
              <select name="cadence" class="select select-sm">
                <option
                  :for={{value, label} <- cadence_options()}
                  value={value}
                  selected={to_string(subscription.cadence) == value}
                >
                  {label}
                </option>
              </select>
            </form>
            <.button
              id={"unsubscribe-#{subscription.id}"}
              phx-click="unsubscribe"
              phx-value-subscription-id={subscription.id}
              data-confirm={gettext("Unsubscribe from this group?")}
              class="btn btn-sm btn-outline"
            >
              {gettext("Unsubscribe")}
            </.button>
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
         |> assign(:claims, state.claims)
         |> assign(:comments, state.comments)
         |> assign(:subscriptions, state.subscriptions)}

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

  def handle_event("release_claim", %{"claim-id" => claim_id}, socket) do
    case Events.unclaim_slot_by_token(socket.assigns.token, claim_id) do
      {:ok, _claim} ->
        {:noreply,
         socket
         |> reload_state()
         |> put_flash(:info, gettext("Your signup is released."))}

      {:error, :invalid} ->
        {:noreply, put_flash(socket, :error, gettext("That link is invalid or has expired."))}
    end
  end

  def handle_event(
        "change_cadence",
        %{"subscription_id" => subscription_id, "cadence" => cadence},
        socket
      ) do
    cadence_atom = String.to_existing_atom(cadence)

    case Newsletters.update_cadence(socket.assigns.token, subscription_id, cadence_atom) do
      {:ok, _subscription} ->
        {:noreply,
         socket
         |> reload_state()
         |> put_flash(:info, gettext("Updated."))}

      {:error, :invalid} ->
        {:noreply, put_flash(socket, :error, gettext("That link is invalid or has expired."))}
    end
  end

  def handle_event("unsubscribe", %{"subscription-id" => subscription_id}, socket) do
    case Newsletters.unsubscribe_by_token(socket.assigns.token, subscription_id) do
      :ok ->
        {:noreply,
         socket
         |> reload_state()
         |> put_flash(:info, gettext("You're unsubscribed."))}

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
        |> assign(:claims, state.claims)
        |> assign(:comments, state.comments)
        |> assign(:subscriptions, state.subscriptions)

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

  defp cadence_options do
    Enum.map(NewsletterSubscription.cadences(), fn cadence ->
      {Atom.to_string(cadence), cadence_label(cadence)}
    end)
  end

  defp cadence_label(:per_post), do: gettext("Every new post")
  defp cadence_label(:daily), do: gettext("Daily digest")
  defp cadence_label(:weekly), do: gettext("Weekly digest")
end
