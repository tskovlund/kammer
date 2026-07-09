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

  alias Kammer.Notifications
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
    case Notifications.get_notification(socket.assigns.current_user, notification_id) do
      nil -> :ok
      notification -> push(socket, "notification_created", Serializer.notification(notification))
    end

    {:noreply, socket}
  end

  def handle_info({Kammer.Notifications, _other_event}, socket), do: {:noreply, socket}
end
