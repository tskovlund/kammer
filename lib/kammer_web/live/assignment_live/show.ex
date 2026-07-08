defmodule KammerWeb.AssignmentLive.Show do
  @moduledoc """
  One assignment (issue #17): the context notes, who's on it, the state
  controls, and the discussion thread — the one comment engine's third
  subject (ADR 0007).
  """

  use KammerWeb, :live_view

  import KammerWeb.FeedComponents, only: [relative_time: 1]
  import KammerWeb.KammerComponents

  alias Kammer.Assignments
  alias Kammer.Assignments.Assignment
  alias Kammer.Feed
  alias KammerWeb.AssignmentEventHandlers
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
      current_tab={:groups}
    >
      <.header>
        {@assignment.title}
        <:subtitle>
          <span class="flex flex-wrap items-center gap-1.5">
            <.link
              navigate={~p"/c/#{@active_community.slug}/g/#{@group.slug}/assignments"}
              class="link"
            >
              {@group.name}
            </.link>
            <span :if={Assignment.done?(@assignment)} class="badge badge-success badge-sm">
              {gettext("Done")}
            </span>
            <span :if={@assignment.due_at} class="text-base-content/50">
              · {gettext("Due %{date}", date: format_due(@assignment.due_at, @timezone))}
            </span>
          </span>
        </:subtitle>
        <:actions>
          <.button
            :if={@can_manage?}
            phx-click="delete"
            data-confirm={gettext("Delete this assignment and its discussion?")}
            class="btn btn-ghost btn-sm text-error"
          >
            {gettext("Delete")}
          </.button>
        </:actions>
      </.header>

      <div
        :if={@assignment.notes_markdown}
        class="prose prose-sm max-w-none dark:prose-invert"
      >
        {Phoenix.HTML.raw(Kammer.Markdown.to_html(@assignment.notes_markdown))}
      </div>

      <section class="rounded-box border border-base-200 p-4">
        <div class="flex flex-wrap items-center gap-2">
          <%= if @assignment.claims == [] and not Assignment.done?(@assignment) do %>
            <p class="text-sm text-base-content/60">{gettext("Up for grabs")}</p>
          <% else %>
            <div class="flex flex-wrap items-center gap-1.5">
              <.user_avatar
                :for={claim <- @assignment.claims}
                user={claim.user}
                size_class="size-7"
                text_class="text-xs"
              />
              <span class="text-sm text-base-content/70">
                {@assignment.claims |> Enum.map(& &1.user.display_name) |> Enum.join(", ")}
              </span>
            </div>
          <% end %>

          <span class="ml-auto flex gap-1.5">
            <.button
              :if={not Assignment.done?(@assignment) and not mine?(@assignment, @current_scope.user)}
              id="claim-button"
              phx-click="claim"
              class="btn btn-primary btn-sm"
            >
              {gettext("I'll take it")}
            </.button>
            <.button
              :if={not Assignment.done?(@assignment) and mine?(@assignment, @current_scope.user)}
              id="unclaim-button"
              phx-click="unclaim"
              class="btn btn-outline btn-sm"
            >
              {gettext("Give it up")}
            </.button>
            <.button
              :if={not Assignment.done?(@assignment)}
              id="complete-button"
              phx-click="complete"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-check" class="size-4" /> {gettext("Done")}
            </.button>
            <.button
              :if={Assignment.done?(@assignment)}
              id="reopen-button"
              phx-click="reopen"
              class="btn btn-ghost btn-sm"
            >
              {gettext("Reopen")}
            </.button>
          </span>
        </div>
        <p
          :if={Assignment.done?(@assignment) and @assignment.completed_by_user}
          class="pt-2 text-xs text-base-content/50"
        >
          {gettext("Finished by %{name}", name: @assignment.completed_by_user.display_name)}
        </p>
      </section>

      <%!-- Discussion (the one comment engine, ADR 0007) --%>
      <section class="space-y-3">
        <h2 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Discussion")}
        </h2>

        <div :for={comment <- top_level_comments(@assignment)} class="space-y-2">
          <.assignment_comment
            comment={comment}
            current_user={@current_scope.user}
            can_moderate={@can_manage?}
          />
          <div class="ml-10 space-y-2 border-l border-base-200 pl-3">
            <.assignment_comment
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

        <form
          :if={@can_comment?}
          id="assignment-comment-form"
          phx-submit="create_comment"
          class="flex items-start gap-2"
        >
          <textarea
            name="body_markdown"
            rows="1"
            required
            placeholder={gettext("Write a comment…")}
            class="textarea textarea-sm min-h-9 flex-1"
          ></textarea>
          <button type="submit" class="btn btn-primary btn-sm">{gettext("Reply")}</button>
        </form>
      </section>

      <.report_modal reporting={@reporting} />
    </Layouts.app>
    """
  end

  attr :comment, :map, required: true
  attr :current_user, :map, default: nil
  attr :can_moderate, :boolean, default: false

  defp assignment_comment(assigns) do
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
  def mount(%{"assignment_id" => assignment_id}, _session, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    case Assignments.fetch_viewable_assignment(current_user, assignment_id) do
      {:ok, assignment, group} ->
        {:ok,
         socket
         |> assign(:assignment_id, assignment.id)
         |> assign(:timezone, current_user.timezone)
         |> assign(:reporting, nil)
         |> load_assignment(assignment, group)}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Not found."))
         |> push_navigate(to: ~p"/c/#{community.slug}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("claim", _params, socket) do
    AssignmentEventHandlers.handle_claim(socket, socket.assigns.assignment, &reload/1)
  end

  def handle_event("unclaim", _params, socket) do
    AssignmentEventHandlers.handle_unclaim(socket, socket.assigns.assignment.id, &reload/1)
  end

  def handle_event("complete", _params, socket) do
    AssignmentEventHandlers.handle_complete(socket, socket.assigns.assignment, &reload/1)
  end

  def handle_event("reopen", _params, socket) do
    AssignmentEventHandlers.handle_reopen(socket, socket.assigns.assignment, &reload/1)
  end

  def handle_event("delete", _params, socket) do
    community = socket.assigns.active_community
    group = socket.assigns.group

    case Assignments.delete_assignment(
           socket.assigns.current_scope.user,
           socket.assigns.assignment
         ) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Assignment deleted."))
         |> push_navigate(to: ~p"/c/#{community.slug}/g/#{group.slug}/assignments")}

      {:error, _reason} ->
        {:noreply, refuse(socket)}
    end
  end

  def handle_event("create_comment", params, socket) do
    case Assignments.create_comment(
           socket.assigns.current_scope.user,
           socket.assigns.assignment,
           params
         ) do
      {:ok, _comment} -> {:noreply, reload(socket)}
      {:error, _reason} -> {:noreply, refuse(socket)}
    end
  end

  def handle_event("delete_comment", %{"id" => comment_id}, socket) do
    with %Kammer.Feed.Comment{} = comment <- Feed.get_comment(comment_id),
         {:ok, _deleted} <- Feed.delete_comment(socket.assigns.current_scope.user, comment) do
      {:noreply, reload(socket)}
    else
      _error -> {:noreply, refuse(socket)}
    end
  end

  def handle_event(report_event, params, socket)
      when report_event in ~w(start_report cancel_report submit_report) do
    ReportHandlers.handle(report_event, params, socket)
  end

  defp reload(socket) do
    current_user = socket.assigns.current_scope.user

    case Assignments.fetch_viewable_assignment(current_user, socket.assigns.assignment_id) do
      {:ok, assignment, group} -> load_assignment(socket, assignment, group)
      {:error, _reason} -> socket
    end
  end

  defp load_assignment(socket, assignment, group) do
    current_user = socket.assigns.current_scope.user
    relationship = Kammer.Authorization.relationship(current_user, group)

    socket
    |> assign(:assignment, assignment)
    |> assign(:group, group)
    |> assign(:can_manage?, Assignments.can_manage_assignment?(current_user, assignment, group))
    |> assign(
      :can_comment?,
      Kammer.Authorization.can?(current_user, :comment_in_group, group, relationship)
    )
  end

  defp refuse(socket) do
    put_flash(socket, :error, gettext("You are not allowed to do that."))
  end

  defp mine?(assignment, user) do
    Enum.any?(assignment.claims, &(&1.user_id == user.id))
  end

  defp top_level_comments(assignment) do
    assignment.comments
    |> Enum.filter(&is_nil(&1.parent_comment_id))
    |> Enum.sort_by(& &1.inserted_at, DateTime)
  end

  defp sorted(comments), do: Enum.sort_by(comments, & &1.inserted_at, DateTime)

  defp format_due(due_at, timezone) do
    shifted =
      case DateTime.shift_zone(due_at, timezone) do
        {:ok, ok} -> ok
        {:error, _reason} -> due_at
      end

    Calendar.strftime(shifted, "%a %d %b %Y · %H:%M")
  end
end
