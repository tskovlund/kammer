defmodule KammerWeb.ModerationLive.Index do
  @moduledoc """
  The moderation queue (SPEC §11): open reports for community admins
  (all of them) and group moderators (their groups'), with dismiss and
  remove-content actions, plus the community's active bans (admins).
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

  alias Kammer.Feed.Comment
  alias Kammer.Feed.Post
  alias Kammer.Moderation
  alias Kammer.Moderation.Report

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
      current_tab={:moderation}
    >
      <.header>
        {gettext("Moderation")}
        <:subtitle>
          {gettext("Reports land here; only you and the other moderators see them.")}
        </:subtitle>
      </.header>

      <section class="space-y-2">
        <div
          :for={report <- @reports}
          id={"report-#{report.id}"}
          class="rounded-box border border-base-200 p-4"
        >
          <p class="text-xs text-base-content/60">
            {gettext("Reported by %{name}",
              name:
                (report.reporter_user && report.reporter_user.display_name) || gettext("Deleted user")
            )} · {Calendar.strftime(report.inserted_at, "%d %b %H:%M")}
          </p>
          <p class="pt-1 text-sm font-medium">{report.reason}</p>

          <blockquote class="mt-2 border-l-2 border-base-300 pl-3 text-sm text-base-content/80">
            {subject_excerpt(report)}
            <span class="block pt-1 text-xs text-base-content/50">
              — {subject_author(report)}
            </span>
          </blockquote>

          <div class="flex gap-2 pt-3">
            <.button
              id={"dismiss-report-#{report.id}"}
              phx-click="dismiss"
              phx-value-id={report.id}
              class="btn btn-ghost btn-sm"
            >
              {gettext("Dismiss")}
            </.button>
            <.button
              id={"resolve-report-#{report.id}"}
              phx-click="resolve"
              phx-value-id={report.id}
              data-confirm={gettext("Remove the reported content? This cannot be undone.")}
              class="btn btn-outline btn-sm text-error"
            >
              {gettext("Remove content")}
            </.button>
          </div>
        </div>

        <.empty_state
          :if={@reports == []}
          icon="hero-shield-check"
          headline={gettext("No open reports")}
          description={gettext("A calm queue is a healthy community.")}
        />
      </section>

      <section :if={@bans != []} class="pt-6">
        <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Active bans")}
        </h2>
        <div
          :for={ban <- @bans}
          class="flex items-center gap-3 rounded-box border border-base-200 p-3"
        >
          <div class="min-w-0 flex-1">
            <p class="truncate font-medium">{ban.email}</p>
            <p class="text-xs text-base-content/60">
              {Calendar.strftime(ban.inserted_at, "%d %b %Y")}
              <span :if={ban.reason}>· {ban.reason}</span>
            </p>
          </div>
          <.button
            id={"unban-#{ban.id}"}
            phx-click="unban"
            phx-value-id={ban.id}
            data-confirm={gettext("Lift this ban?")}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Lift ban")}
          </.button>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, reload(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("dismiss", %{"id" => report_id}, socket) do
    current_user = socket.assigns.current_scope.user

    with %Report{} = report <- Kammer.Repo.get(Report, report_id),
         {:ok, _report} <- Moderation.dismiss_report(current_user, report) do
      {:noreply, reload(socket)}
    else
      _error -> {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("resolve", %{"id" => report_id}, socket) do
    current_user = socket.assigns.current_scope.user

    with %Report{} = report <- Kammer.Repo.get(Report, report_id),
         {:ok, _report} <- Moderation.resolve_report(current_user, report) do
      {:noreply, socket |> put_flash(:info, gettext("Content removed.")) |> reload()}
    else
      _error -> {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("unban", %{"id" => ban_id}, socket) do
    current_user = socket.assigns.current_scope.user

    with %Moderation.CommunityBan{} = ban <- Kammer.Repo.get(Moderation.CommunityBan, ban_id),
         {:ok, _ban} <- Moderation.unban(current_user, ban) do
      {:noreply, reload(socket)}
    else
      _error -> {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  defp reload(socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    socket
    |> assign(:reports, Moderation.list_open_reports(current_user, community))
    |> assign(:bans, Moderation.list_bans(current_user, community))
  end

  defp subject_excerpt(%Report{post: %Post{} = post}) do
    excerpt(post.body_markdown) || gettext("(no text)")
  end

  defp subject_excerpt(%Report{comment: %Comment{} = comment}) do
    excerpt(comment.body_markdown) || gettext("(no text)")
  end

  defp subject_excerpt(_report), do: gettext("(no text)")

  defp subject_author(%Report{post: %Post{author_user: %{display_name: name}}}), do: name

  defp subject_author(%Report{comment: %Comment{author_user: %{display_name: name}}}), do: name

  defp subject_author(_report), do: gettext("Deleted user")

  defp excerpt(nil), do: nil
  defp excerpt(markdown), do: markdown |> String.replace(~r/\s+/, " ") |> String.slice(0, 240)
end
