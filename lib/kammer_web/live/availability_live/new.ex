defmodule KammerWeb.AvailabilityLive.New do
  @moduledoc """
  Create a date-finding poll (issue #39): a title and a handful of
  candidate dates. Gated by the group's `:availability` feature and the
  posting policy — the same rule as creating an event.
  """

  use KammerWeb, :live_view

  alias Kammer.Authorization
  alias Kammer.Availability
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
      unread_notifications={@unread_notifications}
      current_tab={:events}
    >
      <div class="mx-auto max-w-lg">
        <.header>
          {gettext("Find a date")}
          <:subtitle>{@group.name}</:subtitle>
        </.header>

        <.form for={@form} id="availability-form" phx-submit="save" class="space-y-4 pt-4">
          <.input
            field={@form[:title]}
            type="text"
            label={gettext("What are you planning?")}
            placeholder={gettext("e.g. Spring board meeting")}
            required
          />

          <fieldset class="space-y-2">
            <legend class="text-sm font-medium">
              {gettext("Candidate dates (in your timezone)")}
            </legend>
            <input
              :for={index <- 0..(@option_count - 1)}
              type="datetime-local"
              name={"poll[options][#{index}]"}
              value={@form.params["options"]["#{index}"]}
              class="input w-full"
            />
            <button type="button" phx-click="add_option" class="btn btn-ghost btn-xs">
              <.icon name="hero-plus" class="size-3.5" /> {gettext("Add a date")}
            </button>
          </fieldset>

          <div class="flex gap-2">
            <.button variant="primary" phx-disable-with={gettext("Creating...")}>
              {gettext("Start the poll")}
            </.button>
            <.link
              navigate={~p"/c/#{@active_community.slug}/g/#{@group.slug}"}
              class="btn btn-ghost"
            >
              {gettext("Cancel")}
            </.link>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"group_slug" => group_slug}, _session, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    with {:ok, group} <- Groups.fetch_viewable_group(current_user, community, group_slug),
         :ok <- Authorization.feature_gate(group, :availability),
         :ok <- Authorization.authorize(current_user, :post_in_group, group) do
      {:ok,
       socket
       |> assign(:group, group)
       |> assign(:option_count, 3)
       |> assign(:form, to_form(%{}, as: "poll"))}
    else
      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Not found."))
         |> push_navigate(to: ~p"/c/#{community.slug}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("add_option", _params, socket) do
    {:noreply, assign(socket, :option_count, socket.assigns.option_count + 1)}
  end

  def handle_event("save", %{"poll" => poll_params}, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community
    group = socket.assigns.group

    option_starts =
      poll_params
      |> Map.get("options", %{})
      |> Map.values()
      |> Enum.map(&parse_local_datetime(&1, current_user))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case Availability.create_poll(current_user, group, poll_params, option_starts) do
      {:ok, poll} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Poll created — time to collect answers."))
         |> push_navigate(to: ~p"/c/#{community.slug}/availability/#{poll.id}")}

      {:error, :no_options} ->
        {:noreply,
         socket
         |> assign(:form, to_form(poll_params, as: "poll"))
         |> put_flash(:error, gettext("Add at least one candidate date."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> assign(:form, to_form(poll_params, as: "poll"))
         |> put_flash(:error, gettext("Please give the poll a title."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  defp parse_local_datetime(nil, _user), do: nil
  defp parse_local_datetime("", _user), do: nil

  defp parse_local_datetime(value, user) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(value <> ":00"),
         {:ok, local} <- DateTime.from_naive(naive, user.timezone) do
      DateTime.shift_zone!(local, "Etc/UTC")
    else
      _error -> nil
    end
  end
end
