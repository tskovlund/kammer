defmodule KammerWeb.EventLive.New do
  @moduledoc """
  Event creation (SPEC §6): title, Markdown description, timezone-aware
  start/end in the user's timezone, all-day/multi-day, location with
  optional URL, host group (groups where the actor may post).
  """

  use KammerWeb, :live_view

  alias Kammer.Authorization
  alias Kammer.Events
  alias Kammer.Events.Event
  alias Kammer.Groups

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
      current_tab={:events}
    >
      <.header>{gettext("New event")}</.header>

      <.form for={@form} id="event_form" phx-submit="save">
        <.input
          name="event[group_id]"
          type="select"
          label={gettext("Host group")}
          options={Enum.map(@postable_groups, &{&1.name, &1.id})}
          value={@selected_group_id}
          errors={[]}
        />
        <.input field={@form[:title]} type="text" label={gettext("Title")} required />
        <.input
          field={@form[:description_markdown]}
          type="textarea"
          label={gettext("Description")}
        />
        <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
          <.input
            name="event[starts_on]"
            type="date"
            label={gettext("Starts")}
            value=""
            errors={[]}
            required
          />
          <.input name="event[starts_time]" type="time" label={gettext("Time")} value="" errors={[]} />
          <.input
            name="event[ends_on]"
            type="date"
            label={gettext("Ends (optional)")}
            value=""
            errors={[]}
          />
          <.input name="event[ends_time]" type="time" label={gettext("Time")} value="" errors={[]} />
        </div>
        <.input
          name="event[all_day]"
          type="checkbox"
          label={gettext("All-day event")}
          value={false}
          errors={[]}
        />
        <.input field={@form[:location_name]} type="text" label={gettext("Location")} />
        <.input field={@form[:location_url]} type="url" label={gettext("Location link (optional)")} />

        <p class="text-sm text-base-content/60">
          {gettext("Times are in your timezone (%{timezone}).",
            timezone: @current_scope.user.timezone
          )}
        </p>

        <.button variant="primary" phx-disable-with={gettext("Creating...")}>
          {gettext("Create event")}
        </.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    postable_groups =
      current_user
      |> Groups.list_active_groups(community)
      |> Enum.filter(fn group -> Authorization.can?(current_user, :post_in_group, group) end)

    if postable_groups == [] do
      {:ok,
       socket
       |> put_flash(:error, gettext("Join a group before creating events."))
       |> push_navigate(to: ~p"/c/#{community.slug}/events")}
    else
      {:ok,
       socket
       |> assign(:postable_groups, postable_groups)
       |> assign(:selected_group_id, hd(postable_groups).id)
       |> assign(:form, to_form(Events.change_event(%Event{})))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"event" => event_params}, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    group =
      Enum.find(socket.assigns.postable_groups, fn group ->
        group.id == event_params["group_id"]
      end)

    attrs = build_attrs(event_params, current_user)

    with %{} = group <- group || :no_group,
         {:ok, event} <- Events.create_event(current_user, group, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Event created."))
       |> push_navigate(to: ~p"/c/#{community.slug}/events/#{event.id}")}
    else
      :no_group ->
        {:noreply, put_flash(socket, :error, gettext("Pick a host group."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  defp build_attrs(event_params, current_user) do
    all_day = event_params["all_day"] == "true"
    timezone = current_user.timezone

    starts_at =
      compose_datetime(event_params["starts_on"], event_params["starts_time"], all_day, timezone)

    ends_at =
      compose_datetime(event_params["ends_on"], event_params["ends_time"], all_day, timezone)

    event_params
    |> Map.take(["title", "description_markdown", "location_name", "location_url"])
    |> Map.merge(%{
      "starts_at" => starts_at,
      "ends_at" => ends_at,
      "all_day" => all_day,
      "timezone" => timezone
    })
  end

  defp compose_datetime(date_string, time_string, all_day, timezone)

  defp compose_datetime(empty, _time, _all_day, _timezone) when empty in [nil, ""], do: nil

  defp compose_datetime(date_string, time_string, all_day, timezone) do
    time_string =
      if all_day or time_string in [nil, ""] do
        "00:00"
      else
        time_string
      end

    with {:ok, naive} <- NaiveDateTime.from_iso8601("#{date_string}T#{time_string}:00"),
         {:ok, local} <- DateTime.from_naive(naive, timezone) do
      DateTime.shift_zone!(local, "Etc/UTC")
    else
      _error -> nil
    end
  end
end
