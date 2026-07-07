defmodule KammerWeb.InstanceLive.Home do
  @moduledoc """
  Instance landing page: signed-in users see their communities (and jump
  straight in); visitors see the product ethos and the communities that
  opted into being listed (SPEC §3: `listed_on_instance`, default off).
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

  alias Kammer.Communities

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div
        :if={@operator? and not @imprint_published?}
        class="alert alert-warning mb-4 text-sm"
        role="status"
      >
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          {gettext(
            "Your imprint still shows the built-in template. Publish your own before inviting members."
          )}
        </span>
        <.link navigate={~p"/legal/imprint/edit"} class="btn btn-sm">
          {gettext("Edit imprint")}
        </.link>
      </div>

      <div :if={@operator? and @update_available?} class="alert alert-info mb-4 text-sm" role="status">
        <.icon name="hero-arrow-up-circle" class="size-5" />
        <span>
          {gettext("A newer version of Kammer is available (%{version}).",
            version: @latest_known_version
          )}
        </span>
        <a href={@latest_known_release_url} class="btn btn-sm" target="_blank" rel="noopener">
          {gettext("View release")}
        </a>
      </div>

      <div :if={@operator?} class="mb-4 flex justify-end">
        <.link navigate={~p"/instance/settings"} class="text-sm text-base-content/60 hover:underline">
          {gettext("Instance settings")}
        </.link>
      </div>

      <%= if @current_scope && @current_scope.user do %>
        <.header>
          {gettext("Your communities")}
          <:subtitle :if={@my_communities != []}>
            {gettext("Pick a community to continue.")}
          </:subtitle>
        </.header>

        <div :if={@my_communities != []} class="space-y-2">
          <.link
            :for={community <- @my_communities}
            navigate={~p"/c/#{community.slug}"}
            class="flex items-center gap-3 rounded-box border border-base-200 p-4 hover:bg-base-200"
          >
            <.community_avatar community={community} size_class="size-10" />
            <div class="min-w-0">
              <p class="truncate font-medium">{community.name}</p>
              <p :if={community.description} class="truncate text-sm text-base-content/60">
                {community.description}
              </p>
            </div>
            <.icon name="hero-chevron-right" class="ml-auto size-5 text-base-content/40" />
          </.link>
        </div>

        <%!-- Home (ADR 0015): one merged, chronological lens across
             everything the user belongs to. Read-only by design. --%>
        <section :if={@home_events != []} class="pt-8">
          <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
            {gettext("Coming up")}
          </h2>
          <div class="space-y-2" id="home-events">
            <.link
              :for={event <- @home_events}
              navigate={~p"/c/#{event.group.community.slug}/events/#{event.id}"}
              class="flex items-center gap-3 rounded-box border border-base-200 p-3 hover:bg-base-200"
            >
              <.icon name="hero-calendar-days" class="size-5 text-[var(--accent,#3E6B48)]" />
              <div class="min-w-0">
                <p class="truncate font-medium">{event.title}</p>
                <p class="truncate text-sm text-base-content/60">
                  {Calendar.strftime(event.starts_at, "%d %b · %H:%M")} · {event.group.community.name} / {event.group.name}
                </p>
              </div>
            </.link>
          </div>
        </section>

        <section :if={@home_posts != []} class="pt-8">
          <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
            {gettext("Recent activity")}
          </h2>
          <div class="space-y-2" id="home-activity">
            <.link
              :for={post <- @home_posts}
              navigate={~p"/c/#{post.group.community.slug}/g/#{post.group.slug}"}
              class="block rounded-box border border-base-200 p-3 hover:bg-base-200"
            >
              <p class="truncate text-sm text-base-content/60">
                {post.group.community.name} / {post.group.name}
                <span :if={post.author_user}>· {post.author_user.display_name}</span>
              </p>
              <p class="line-clamp-2 text-sm">{excerpt(post.body_markdown)}</p>
            </.link>
          </div>
          <p class="pt-2 text-xs text-base-content/50">
            {gettext(
              "Home shows the groups you belong to, newest first. Each group page has a \"Show in Home\" switch if you want one out of here."
            )}
          </p>
        </section>

        <div
          :if={@operator? and @demo_community}
          class="mt-4 flex items-center justify-between gap-3 rounded-box border border-dashed border-base-300 p-4 text-sm"
        >
          <span class="text-base-content/70">
            {gettext("The demo community “%{name}” is still around.", name: @demo_community.name)}
          </span>
          <button
            type="button"
            phx-click="purge_demo"
            data-confirm={gettext("Delete the demo community and everything in it?")}
            class="btn btn-outline btn-error btn-sm"
          >
            {gettext("Remove demo")}
          </button>
        </div>

        <.empty_state
          :if={@my_communities == []}
          icon="hero-user-group"
          headline={gettext("You're not in any community yet")}
          description={
            gettext(
              "Communities are joined by invitation. Ask an organizer for an invite link — or create your own community."
            )
          }
        >
          <:action>
            <.link navigate={~p"/communities/new"} class="btn btn-primary btn-sm">
              {gettext("Create a community")}
            </.link>
          </:action>
        </.empty_state>
      <% else %>
        <div class="space-y-6 py-8 text-center">
          <h1 class="text-3xl font-semibold tracking-tight">
            {Application.get_env(:kammer, :product_name, "Kammer")}
          </h1>
          <p class="mx-auto max-w-md text-base-content/70">
            {gettext(
              "A calm, self-hosted home for real-world communities. No ads, no algorithm — just your people."
            )}
          </p>
          <div class="flex justify-center gap-3">
            <.link navigate={~p"/users/log-in"} class="btn btn-primary">
              {gettext("Sign in")}
            </.link>
            <.link navigate={~p"/users/register"} class="btn btn-ghost">
              {gettext("Create an account")}
            </.link>
          </div>
        </div>

        <div :if={@listed_communities != []} class="space-y-2 pt-6">
          <h2 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
            {gettext("Communities on this instance")}
          </h2>
          <.link
            :for={community <- @listed_communities}
            navigate={~p"/c/#{community.slug}"}
            class="flex items-center gap-3 rounded-box border border-base-200 p-4 hover:bg-base-200"
          >
            <.community_avatar community={community} size_class="size-10" />
            <div class="min-w-0">
              <p class="truncate font-medium">{community.name}</p>
              <p :if={community.description} class="truncate text-sm text-base-content/60">
                {community.description}
              </p>
            </div>
          </.link>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("purge_demo", _params, socket) do
    case Kammer.Setup.DemoData.purge(socket.assigns.current_scope.user) do
      {:ok, _community} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Demo community removed."))
         |> refresh()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not remove the demo community."))}
    end
  end

  defp refresh(socket) do
    user =
      case socket.assigns.current_scope do
        %{user: %Kammer.Accounts.User{} = current_user} -> current_user
        _anonymous -> nil
      end

    my_communities = if user, do: Communities.list_user_communities(user), else: []
    operator? = user != nil and user.instance_operator
    instance_settings = if operator?, do: Communities.get_instance_settings()

    demo_community =
      if operator? do
        case instance_settings.demo_community_id do
          nil -> nil
          community_id -> Kammer.Repo.get(Kammer.Communities.Community, community_id)
        end
      end

    socket
    |> assign(:home_events, if(user, do: Kammer.Home.upcoming_events(user), else: []))
    |> assign(:home_posts, if(user, do: Kammer.Home.recent_activity(user), else: []))
    |> assign(:my_communities, my_communities)
    |> assign(:listed_communities, Communities.list_public_communities())
    |> assign(:operator?, operator?)
    |> assign(:imprint_published?, not operator? or Kammer.Legal.published?("imprint"))
    |> assign(
      :update_available?,
      operator? and Kammer.UpdateCheck.update_available?(instance_settings)
    )
    |> assign(:latest_known_version, operator? && instance_settings.latest_known_version)
    |> assign(
      :latest_known_release_url,
      operator? && instance_settings.latest_known_release_url
    )
    |> assign(:demo_community, demo_community)
  end

  defp excerpt(markdown) do
    markdown
    |> String.replace(~r/[#*_>`\[\]()!-]/, "")
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||("")
  end
end
