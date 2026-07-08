defmodule KammerWeb.AssignmentLive.Index do
  @moduledoc """
  A group's assignment list (issue #17, owner-designed): one flat list —
  open first, done below — with one-tap claiming and completing. No
  columns, no sprints; associations run on lists and volunteering.
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

  alias Kammer.Assignments
  alias Kammer.Assignments.Assignment
  alias Kammer.Authorization
  alias Kammer.Groups
  alias KammerWeb.AssignmentEventHandlers

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
      current_tab={:groups}
    >
      <.header>
        {gettext("Assignments")}
        <:subtitle>{@group.name}</:subtitle>
      </.header>

      <%!-- New assignment --%>
      <form
        :if={@can_create?}
        id="new-assignment-form"
        phx-submit="create"
        class="flex flex-wrap items-end gap-2 rounded-box border border-base-200 p-4"
      >
        <label class="flex flex-1 basis-64 flex-col gap-1 text-xs text-base-content/60">
          {gettext("What needs doing?")}
          <input
            type="text"
            name="assignment[title]"
            required
            placeholder={gettext("e.g. Order new sheet music")}
            class="input input-sm"
          />
        </label>
        <label class="flex flex-col gap-1 text-xs text-base-content/60">
          {gettext("Due (optional)")}
          <input type="datetime-local" name="assignment[due_for]" class="input input-sm" />
        </label>
        <button type="submit" class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="size-4" /> {gettext("Add")}
        </button>
      </form>

      <section class="space-y-2">
        <div
          :for={assignment <- @assignments}
          id={"assignment-#{assignment.id}"}
          class={[
            "flex flex-wrap items-center gap-3 rounded-box border border-base-200 p-4",
            Assignment.done?(assignment) && "opacity-60"
          ]}
        >
          <.icon
            name={if Assignment.done?(assignment), do: "hero-check-circle", else: "hero-circle-stack"}
            class={[
              "size-5 shrink-0",
              (Assignment.done?(assignment) && "text-success") || "text-base-content/30"
            ]}
          />
          <div class="min-w-0 flex-1">
            <.link
              navigate={
                ~p"/c/#{@active_community.slug}/g/#{@group.slug}/assignments/#{assignment.id}"
              }
              class="font-medium hover:underline"
            >
              {assignment.title}
            </.link>
            <p class="text-xs text-base-content/60">
              <span :if={assignment.due_at}>
                {gettext("Due %{date}", date: format_due(assignment.due_at, @timezone))} ·
              </span>
              <%= if assignment.claims == [] and not Assignment.done?(assignment) do %>
                {gettext("Up for grabs")}
              <% else %>
                {assignment.claims |> Enum.map(& &1.user.display_name) |> Enum.join(", ")}
              <% end %>
            </p>
          </div>

          <span class="flex shrink-0 gap-1.5">
            <.button
              :if={not Assignment.done?(assignment) and not mine?(assignment, @current_scope.user)}
              id={"claim-#{assignment.id}"}
              phx-click="claim"
              phx-value-id={assignment.id}
              class="btn btn-primary btn-xs"
            >
              {gettext("I'll take it")}
            </.button>
            <.button
              :if={not Assignment.done?(assignment) and mine?(assignment, @current_scope.user)}
              id={"unclaim-#{assignment.id}"}
              phx-click="unclaim"
              phx-value-id={assignment.id}
              class="btn btn-outline btn-xs"
            >
              {gettext("Give it up")}
            </.button>
            <.button
              :if={not Assignment.done?(assignment)}
              id={"complete-#{assignment.id}"}
              phx-click="complete"
              phx-value-id={assignment.id}
              class="btn btn-ghost btn-xs"
            >
              <.icon name="hero-check" class="size-3.5" /> {gettext("Done")}
            </.button>
            <.button
              :if={Assignment.done?(assignment)}
              id={"reopen-#{assignment.id}"}
              phx-click="reopen"
              phx-value-id={assignment.id}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Reopen")}
            </.button>
          </span>
        </div>

        <.empty_state
          :if={@assignments == []}
          icon="hero-clipboard-document-check"
          headline={gettext("Nothing to do")}
          description={gettext("Add the first assignment — someone will take it.")}
        />
      </section>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"group_slug" => group_slug}, _session, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    with {:ok, group} <- Groups.fetch_viewable_group(current_user, community, group_slug),
         :ok <- Authorization.feature_gate(group, :assignments) do
      {:ok,
       socket
       |> assign(:group, group)
       |> assign(:timezone, current_user.timezone)
       |> assign(
         :can_create?,
         Authorization.can?(current_user, :post_in_group, group)
       )
       |> reload()}
    else
      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Not found."))
         |> push_navigate(to: ~p"/c/#{community.slug}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("create", %{"assignment" => params}, socket) do
    current_user = socket.assigns.current_scope.user

    attrs =
      case parse_local_datetime(params["due_for"], current_user) do
        nil -> params
        due_at -> Map.put(params, "due_at", due_at)
      end

    case Assignments.create_assignment(current_user, socket.assigns.group, attrs) do
      {:ok, _assignment} ->
        {:noreply, reload(socket)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("Please give the assignment a title."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("claim", %{"id" => assignment_id}, socket) do
    AssignmentEventHandlers.handle_claim(
      socket,
      Assignments.get_assignment(assignment_id),
      &reload/1
    )
  end

  def handle_event("unclaim", %{"id" => assignment_id}, socket) do
    AssignmentEventHandlers.handle_unclaim(socket, assignment_id, &reload/1)
  end

  def handle_event("complete", %{"id" => assignment_id}, socket) do
    AssignmentEventHandlers.handle_complete(
      socket,
      Assignments.get_assignment(assignment_id),
      &reload/1
    )
  end

  def handle_event("reopen", %{"id" => assignment_id}, socket) do
    AssignmentEventHandlers.handle_reopen(
      socket,
      Assignments.get_assignment(assignment_id),
      &reload/1
    )
  end

  defp reload(socket) do
    assign(socket, :assignments, Assignments.list_assignments(socket.assigns.group))
  end

  defp mine?(assignment, user) do
    Enum.any?(assignment.claims, &(&1.user_id == user.id))
  end

  defp format_due(due_at, timezone) do
    shifted =
      case DateTime.shift_zone(due_at, timezone) do
        {:ok, ok} -> ok
        {:error, _reason} -> due_at
      end

    Calendar.strftime(shifted, "%a %d %b")
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
