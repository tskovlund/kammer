defmodule KammerWeb.NotificationLive.Index do
  @moduledoc """
  In-app notification center (SPEC §9): the user's notifications newest
  first with unread markers, mark-all-read, and Web Push enablement
  (browser subscription via the `PushSubscribe` JS hook when the
  instance has VAPID keys).
  """

  use KammerWeb, :live_view

  import KammerWeb.FeedComponents, only: [relative_time: 1]
  import KammerWeb.KammerComponents

  alias Kammer.Feed.Post
  alias Kammer.Notifications

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
      current_tab={:notifications}
    >
      <.header>
        {gettext("Notifications")}
        <:actions>
          <.button :if={@unread_count > 0} phx-click="mark_all_read" class="btn btn-ghost btn-sm">
            {gettext("Mark all read")}
          </.button>
        </:actions>
      </.header>

      <div
        :if={@push_available? and not @push_denied?}
        id="push-subscribe"
        phx-hook="PushSubscribe"
        data-vapid-key={@vapid_public_key}
        class="flex items-center gap-3 rounded-box border border-base-200 p-3 text-sm"
      >
        <.icon name="hero-bell-alert" class="size-5 text-[var(--accent,#3E6B48)]" />
        <span class="flex-1">
          {gettext("Get push notifications on this device for mentions and replies.")}
        </span>
        <button data-push-enable class="btn btn-primary btn-sm">{gettext("Enable")}</button>
      </div>

      <ul :if={@notifications != []} class="space-y-1">
        <li :for={notification <- @notifications}>
          <.link
            navigate={notification_path(notification, @active_community)}
            phx-click="mark_read"
            phx-value-id={notification.id}
            class={[
              "flex items-start gap-3 rounded-field px-3 py-2.5 hover:bg-base-200",
              is_nil(notification.read_at) && "accent-soft"
            ]}
          >
            <.user_avatar
              :if={notification.actor_user && not group_actor?(notification)}
              user={notification.actor_user}
              size_class="size-8"
              text_class="text-xs"
            />
            <div class="min-w-0 flex-1">
              <p class="text-sm">
                {describe(notification)}
              </p>
              <p class="text-xs text-base-content/50">
                {notification.group && notification.group.name} · {relative_time(
                  notification.inserted_at
                )}
              </p>
            </div>
            <span
              :if={is_nil(notification.read_at)}
              class="mt-1.5 size-2 shrink-0 rounded-full bg-[var(--accent,#3E6B48)]"
              aria-label={gettext("Unread")}
            ></span>
          </.link>
        </li>
      </ul>

      <.empty_state
        :if={@notifications == []}
        icon="hero-bell"
        headline={gettext("You're all caught up")}
        description={gettext("Mentions, replies, and event reminders will land here.")}
      />
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:push_available?, Notifications.push_enabled?())
     |> assign(:push_denied?, false)
     |> assign(:vapid_public_key, Notifications.vapid_public_key())
     |> reload()}
  end

  @impl Phoenix.LiveView
  def handle_event("mark_read", %{"id" => notification_id}, socket) do
    Notifications.mark_read(socket.assigns.current_scope.user, notification_id)
    {:noreply, reload(socket)}
  end

  def handle_event("mark_all_read", _params, socket) do
    Notifications.mark_all_read(socket.assigns.current_scope.user)
    {:noreply, reload(socket)}
  end

  def handle_event("push_subscription", subscription_params, socket) do
    case Notifications.register_push_subscription(
           socket.assigns.current_scope.user,
           subscription_params
         ) do
      {:ok, _subscription} ->
        {:noreply, put_flash(socket, :info, gettext("Push notifications enabled."))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not enable push notifications."))}
    end
  end

  def handle_event("push_denied", _params, socket) do
    {:noreply, assign(socket, :push_denied?, true)}
  end

  defp reload(socket) do
    user = socket.assigns.current_scope.user

    socket
    |> assign(:notifications, Notifications.list_notifications(user))
    |> assign(:unread_count, Notifications.unread_count(user))
  end

  defp describe(notification) do
    actor_name = actor_name(notification)

    case notification.kind do
      :mention ->
        gettext("%{name} mentioned you", name: actor_name)

      :reply ->
        gettext("%{name} replied to you", name: actor_name)

      :acknowledgment_required ->
        gettext("%{name} posted something to acknowledge", name: actor_name)

      :event_created ->
        gettext("%{name} created an event", name: actor_name)

      :event_reminder ->
        gettext("Event reminder")

      :post ->
        gettext("%{name} posted", name: actor_name)
    end
  end

  # A notification about a group-authored post (no comment involved —
  # comments always have a human author). Posting "as the group" exists
  # to hide the human author, so the actor rendered is the group (#167),
  # matching `feed_components.ex`, digests, and newsletters.
  defp group_actor?(%{comment_id: nil, post: %Post{author_type: :group}}), do: true
  defp group_actor?(_notification), do: false

  defp actor_name(notification) do
    cond do
      group_actor?(notification) ->
        (notification.group && notification.group.name) || gettext("The group")

      notification.actor_user ->
        notification.actor_user.display_name

      true ->
        gettext("Someone")
    end
  end

  defp notification_path(notification, community) do
    cond do
      notification.event_id ->
        ~p"/c/#{community.slug}/events/#{notification.event_id}"

      notification.group ->
        ~p"/c/#{community.slug}/g/#{notification.group.slug}"

      true ->
        ~p"/c/#{community.slug}"
    end
  end
end
