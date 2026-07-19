defmodule KammerWeb.Api.NotificationChannel do
  @moduledoc """
  The device owner's notification stream (ADR 0014): the channel topic
  is the exact PubSub topic `Kammer.Notifications` broadcasts on
  (`notifications:user:<id>`), joinable only as oneself — there is no
  cross-user notification access on any transport. Each event is
  re-fetched owner-scoped and shaped by the REST serializer, so the
  push matches `GET /api/v1/notifications` entries byte for byte.
  """

  use Phoenix.Channel

  alias Kammer.Authorization
  alias Kammer.Groups.Group
  alias Kammer.Notifications
  alias Kammer.Notifications.Notification
  alias KammerWeb.Api.Serializer

  @impl Phoenix.Channel
  def join("notifications:user:" <> user_id, _payload, socket) do
    if user_id == socket.assigns.current_user.id do
      {:ok, socket}
    else
      {:error, %{error: %{code: "not_found", message: "Not found."}}}
    end
  end

  @impl Phoenix.Channel
  def handle_info({Kammer.Notifications, {:notification_created, notification_id}}, socket) do
    user = socket.assigns.current_user

    case Notifications.get_notification(user, notification_id) do
      nil ->
        :ok

      notification ->
        # Re-authorize per push, the way the feed channel does (#377): a
        # membership or visibility change that never severs the socket — a
        # member removed from the group, or the group flipped to private —
        # must still cut the stream, rather than trusting the join-time
        # grant. (A full instance ban is enforced once at the transport, in
        # `UserSocket.connect/3`, plus token revocation, so it never reaches
        # a live channel here.)
        if still_visible?(user, notification) do
          push(socket, "notification_created", Serializer.notification(notification))
        end
    end

    {:noreply, socket}
  end

  def handle_info({Kammer.Notifications, _other_event}, socket), do: {:noreply, socket}

  # A group-scoped notification is re-authorized against the group's live
  # visibility rule — the same `:view_group` decision the feed channel
  # re-runs per push (so a public group stays visible, a lost membership
  # does not). A group-less notification (the column is nullable, though
  # none is created today) has no group access to re-check and is the
  # owner's own, so it stays deliverable.
  defp still_visible?(user, %Notification{group: %Group{} = group}),
    do: Authorization.can?(user, :view_group, group)

  defp still_visible?(_user, %Notification{group: nil}), do: true
end
