defmodule KammerWeb.GuestRsvpLive.Manage do
  @moduledoc """
  A guest's management page (SPEC §6/§12), reached only through the
  signed link in their confirmation email: change the answer, or erase
  everything the instance stores about them. The token in the URL is
  the entire credential.
  """

  use KammerWeb, :live_view

  alias Kammer.Events

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-lg space-y-6">
        <.header>
          {@event.title}
          <:subtitle>{gettext("Your guest RSVP, %{name}", name: @identity.display_name)}</:subtitle>
        </.header>

        <section class="rounded-box border border-base-200 p-4">
          <p class="pb-3 text-sm text-base-content/70">{gettext("Your answer:")}</p>
          <div class="flex flex-wrap gap-2">
            <.button
              :for={{status, label} <- rsvp_options()}
              phx-click="set_status"
              phx-value-status={status}
              class={[
                "btn btn-sm",
                @rsvp && to_string(@rsvp.status) == status && "btn-primary",
                !(@rsvp && to_string(@rsvp.status) == status) && "btn-outline"
              ]}
            >
              {label}
            </.button>
          </div>
        </section>

        <section class="rounded-box border border-base-200 p-4">
          <p class="pb-3 text-sm text-base-content/70">
            {gettext(
              "We store your name, email address, and this RSVP — nothing else. Erasing removes all of it immediately."
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
    case Events.fetch_guest_rsvp(token) do
      {:ok, %{event: event, identity: identity, rsvp: rsvp}} ->
        {:ok,
         socket
         |> assign(:token, token)
         |> assign(:event, event)
         |> assign(:identity, identity)
         |> assign(:rsvp, rsvp)}

      {:error, :invalid} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That link is invalid or has expired."))
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("set_status", %{"status" => status}, socket) do
    status_atom = String.to_existing_atom(status)

    case Events.update_guest_rsvp(socket.assigns.token, status_atom) do
      {:ok, rsvp} ->
        {:noreply,
         socket
         |> assign(:rsvp, rsvp)
         |> put_flash(:info, gettext("Your answer is updated."))}

      {:error, :invalid} ->
        {:noreply, put_flash(socket, :error, gettext("That link is invalid or has expired."))}
    end
  end

  def handle_event("erase", _params, socket) do
    case Events.erase_guest(socket.assigns.token) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Your data has been erased."))
         |> push_navigate(to: ~p"/")}

      {:error, :invalid} ->
        {:noreply, put_flash(socket, :error, gettext("That link is invalid or has expired."))}
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
