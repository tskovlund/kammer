defmodule KammerWeb.SearchLive.Index do
  @moduledoc """
  Community search (SPEC §10): one box, four sections — posts,
  comments, events, files — everything filtered through the same
  listing visibility the rest of the product uses. Anonymous visitors
  search exactly the public face.
  """

  use KammerWeb, :live_view

  import KammerWeb.FeedComponents, only: [author_name: 1, relative_time: 1]
  import KammerWeb.KammerComponents

  alias Kammer.Search

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
      current_tab={:search}
    >
      <.header>{gettext("Search")}</.header>

      <form id="search-form" phx-change="search" phx-submit="search">
        <input
          type="search"
          name="q"
          value={@query}
          placeholder={gettext("Search posts, comments, events, and files…")}
          phx-debounce="300"
          autofocus
          class="input w-full"
        />
      </form>

      <section :if={@results.posts != []} class="space-y-2">
        <h2 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Posts")}
        </h2>
        <.link
          :for={post <- @results.posts}
          id={"search-result-post-#{post.id}"}
          navigate={~p"/c/#{@active_community.slug}/g/#{post.group.slug}" <> "#post-#{post.id}"}
          class="block rounded-box border border-base-200 p-4 hover:bg-base-200"
        >
          <p class="line-clamp-2 text-sm">{excerpt(post.body_markdown)}</p>
          <p class="pt-1 text-xs text-base-content/60">
            {author_name(post)} · {post.group.name} · {relative_time(post.published_at)}
          </p>
        </.link>
      </section>

      <section :if={@results.comments != []} class="space-y-2">
        <h2 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Comments")}
        </h2>
        <.link
          :for={comment <- @results.comments}
          id={"search-result-comment-#{comment.id}"}
          navigate={comment_path(comment, @active_community)}
          class="block rounded-box border border-base-200 p-4 hover:bg-base-200"
        >
          <p class="line-clamp-2 text-sm">{excerpt(comment.body_markdown)}</p>
          <p class="pt-1 text-xs text-base-content/60">
            {(comment.author_user && comment.author_user.display_name) || gettext("Deleted user")} · {comment_context_name(
              comment
            )} · {relative_time(comment.inserted_at)}
          </p>
        </.link>
      </section>

      <section :if={@results.events != []} class="space-y-2">
        <h2 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Events")}
        </h2>
        <.link
          :for={event <- @results.events}
          id={"search-result-event-#{event.id}"}
          navigate={~p"/c/#{@active_community.slug}/events/#{event.id}"}
          class="block rounded-box border border-base-200 p-4 hover:bg-base-200"
        >
          <p class="text-sm font-medium">{event.title}</p>
          <p class="pt-1 text-xs text-base-content/60">
            {Calendar.strftime(event.starts_at, "%d %b %Y")} · {event.group.name}
          </p>
        </.link>
      </section>

      <section :if={@results.files != []} class="space-y-2">
        <h2 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Files")}
        </h2>
        <.link
          :for={file <- @results.files}
          id={"search-result-file-#{file.id}"}
          href={file_href(file)}
          class="block rounded-box border border-base-200 p-4 hover:bg-base-200"
        >
          <p class="text-sm font-medium">{file.filename}</p>
          <p class="pt-1 text-xs text-base-content/60">
            {(file.group && file.group.name) || gettext("Community files")}
          </p>
        </.link>
      </section>

      <.empty_state
        :if={@query != "" and @results == %{posts: [], comments: [], events: [], files: []}}
        icon="hero-magnifying-glass"
        headline={gettext("Nothing found")}
        description={
          gettext("Try different words — search looks at posts, comments, events, and files.")
        }
      />
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:results, %{posts: [], comments: [], events: [], files: []})}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    query = params["q"] || ""
    {:noreply, run_search(socket, query)}
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/c/#{socket.assigns.active_community.slug}/search?#{[q: query]}"
     )}
  end

  defp run_search(socket, query) do
    current_user = current_user(socket.assigns)
    community = socket.assigns.active_community

    socket
    |> assign(:query, query)
    |> assign(:results, Search.search(current_user, community, query))
  end

  defp current_user(%{current_scope: %{user: user}}), do: user
  defp current_user(_assigns), do: nil

  defp excerpt(nil), do: ""

  defp excerpt(markdown) do
    markdown
    |> String.replace(~r/[#*_`>\[\]()!-]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 240)
  end

  defp file_href(file) do
    if file.kind == :image do
      ~p"/files/#{file.id}"
    else
      ~p"/files/#{file.id}/download"
    end
  end

  defp comment_path(comment, community) do
    cond do
      comment.post_id && comment.post ->
        ~p"/c/#{community.slug}/g/#{comment.post.group.slug}" <> "#comment-#{comment.id}"

      comment.event_id ->
        ~p"/c/#{community.slug}/events/#{comment.event_id}"

      comment.assignment_id && comment.assignment ->
        ~p"/c/#{community.slug}/g/#{comment.assignment.group.slug}/assignments/#{comment.assignment_id}"

      true ->
        ~p"/c/#{community.slug}"
    end
  end

  defp comment_context_name(comment) do
    cond do
      comment.post_id && comment.post -> comment.post.group.name
      comment.event_id && comment.event -> comment.event.group.name
      comment.assignment_id && comment.assignment -> comment.assignment.group.name
      true -> ""
    end
  end
end
