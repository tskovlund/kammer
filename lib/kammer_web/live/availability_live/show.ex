defmodule KammerWeb.AvailabilityLive.Show do
  @moduledoc """
  The response grid of a date-finding poll (issue #39): candidate dates
  as rows, one yes / if-needed / no control per date, everyone's
  answers visible (this is coordination, not a secret ballot). The
  poll's creator and group moderators convert the winning date into an
  event or close the poll without one.
  """

  use KammerWeb, :live_view

  alias Kammer.Availability
  alias Kammer.Availability.AvailabilityPoll

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
        {@poll.title}
        <:subtitle>
          <span class="flex flex-wrap items-center gap-1.5">
            {@group.name}
            <span :if={AvailabilityPoll.closed?(@poll)} class="badge badge-ghost badge-sm">
              {gettext("Closed")}
            </span>
          </span>
        </:subtitle>
        <:actions>
          <.button
            :if={@can_manage? and not AvailabilityPoll.closed?(@poll)}
            phx-click="close_poll"
            data-confirm={gettext("Close this poll without creating an event?")}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Close without event")}
          </.button>
        </:actions>
      </.header>

      <p :if={@poll.converted_event_id} class="rounded-box border border-base-200 p-4 text-sm">
        <.icon name="hero-check-circle" class="size-4 text-success" />
        {gettext("This poll became an event:")}
        <.link
          navigate={~p"/c/#{@active_community.slug}/events/#{@poll.converted_event_id}"}
          class="link font-medium"
        >
          {@poll.title}
        </.link>
      </p>

      <section class="space-y-3">
        <div
          :for={option <- @poll.options}
          id={"option-#{option.id}"}
          class="rounded-box border border-base-200 p-4"
        >
          <div class="flex flex-wrap items-center gap-2">
            <p class="font-medium">
              {format_option(option, viewer_timezone(@current_scope))}
            </p>
            <span class="badge badge-ghost badge-sm" title={gettext("yes / if needed")}>
              {yes_count(option)} + {if_needed_count(option)}
            </span>
            <span
              :if={@can_respond? and not AvailabilityPoll.closed?(@poll)}
              class="ml-auto flex gap-1"
            >
              <button
                :for={{answer, label} <- answer_options()}
                id={"answer-#{option.id}-#{answer}"}
                phx-click="respond"
                phx-value-option-id={option.id}
                phx-value-answer={answer}
                class={[
                  "btn btn-xs",
                  my_answer(option, @current_scope.user) == answer && "btn-primary",
                  my_answer(option, @current_scope.user) != answer && "btn-outline"
                ]}
              >
                {label}
              </button>
            </span>
            <.button
              :if={@can_manage? and not AvailabilityPoll.closed?(@poll)}
              id={"convert-#{option.id}"}
              phx-click="convert"
              phx-value-option-id={option.id}
              data-confirm={gettext("Create the event on this date and close the poll?")}
              class="btn btn-outline btn-xs"
            >
              {gettext("Pick this date")}
            </.button>
          </div>

          <div :if={option.responses != []} class="flex flex-wrap gap-x-4 gap-y-1 pt-2 text-sm">
            <span
              :for={response <- sorted_responses(option)}
              class={[
                "flex items-center gap-1",
                response.answer == :yes && "text-success",
                response.answer == :if_needed && "text-warning",
                response.answer == :no && "text-base-content/40"
              ]}
            >
              <.icon name={answer_icon(response.answer)} class="size-3.5" />
              {(response.user && response.user.display_name) || gettext("Deleted user")}
            </span>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"poll_id" => poll_id}, _session, socket) do
    current_user = current_user(socket.assigns)
    community = socket.assigns.active_community

    case Availability.fetch_viewable_poll(current_user, poll_id) do
      {:ok, poll, group} ->
        {:ok, socket |> assign(:poll_id, poll.id) |> load_poll(poll, group)}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Not found."))
         |> push_navigate(to: ~p"/c/#{community.slug}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("respond", %{"option-id" => option_id, "answer" => answer}, socket) do
    current_user = socket.assigns.current_scope.user
    answer_atom = String.to_existing_atom(answer)

    with %Kammer.Availability.AvailabilityOption{} = option <-
           Kammer.Repo.get(Kammer.Availability.AvailabilityOption, option_id),
         {:ok, _response} <- Availability.respond(current_user, option, answer_atom) do
      {:noreply, reload(socket)}
    else
      {:error, :closed} ->
        {:noreply, socket |> put_flash(:error, gettext("This poll is closed.")) |> reload()}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("convert", %{"option-id" => option_id}, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    with %Kammer.Availability.AvailabilityOption{} = option <-
           Kammer.Repo.get(Kammer.Availability.AvailabilityOption, option_id),
         {:ok, _poll, event} <-
           Availability.convert_to_event(current_user, socket.assigns.poll, option) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("The date is set — here's the event."))
       |> push_navigate(to: ~p"/c/#{community.slug}/events/#{event.id}")}
    else
      _error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("close_poll", _params, socket) do
    current_user = socket.assigns.current_scope.user

    case Availability.close_poll(current_user, socket.assigns.poll) do
      {:ok, _poll} ->
        {:noreply, reload(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  defp reload(socket) do
    current_user = current_user(socket.assigns)

    case Availability.fetch_viewable_poll(current_user, socket.assigns.poll_id) do
      {:ok, poll, group} -> load_poll(socket, poll, group)
      {:error, _reason} -> socket
    end
  end

  defp load_poll(socket, poll, group) do
    current_user = current_user(socket.assigns)
    relationship = Kammer.Authorization.relationship(current_user, group)

    socket
    |> assign(:poll, poll)
    |> assign(:group, group)
    |> assign(:can_respond?, Kammer.Authorization.can_react?(current_user, group, relationship))
    |> assign(:can_manage?, Availability.can_manage_poll?(current_user, poll, group))
  end

  defp current_user(%{current_scope: %{user: user}}), do: user
  defp current_user(_assigns), do: nil

  defp viewer_timezone(%{user: %{timezone: timezone}}), do: timezone
  defp viewer_timezone(_scope), do: "Etc/UTC"

  defp format_option(option, timezone) do
    shifted =
      case DateTime.shift_zone(option.starts_at, timezone) do
        {:ok, ok} -> ok
        {:error, _reason} -> option.starts_at
      end

    Calendar.strftime(shifted, "%a %d %b %Y · %H:%M")
  end

  defp answer_options do
    [
      {:yes, gettext("Yes")},
      {:if_needed, gettext("If needed")},
      {:no, gettext("No")}
    ]
  end

  defp answer_icon(:yes), do: "hero-check"
  defp answer_icon(:if_needed), do: "hero-minus"
  defp answer_icon(:no), do: "hero-x-mark"

  defp my_answer(_option, nil), do: nil

  defp my_answer(option, user) do
    Enum.find_value(option.responses, fn response ->
      response.user_id == user.id && response.answer
    end)
  end

  defp yes_count(option), do: Enum.count(option.responses, &(&1.answer == :yes))
  defp if_needed_count(option), do: Enum.count(option.responses, &(&1.answer == :if_needed))

  defp sorted_responses(option) do
    Enum.sort_by(option.responses, fn response ->
      {Enum.find_index([:yes, :if_needed, :no], &(&1 == response.answer)),
       (response.user && response.user.display_name) || ""}
    end)
  end
end
