defmodule KammerWeb.Api.NotificationController do
  @moduledoc """
  The in-app notification center over the API (SPEC §9, issue #30):
  cursor-paginated reads plus mark-read — one and all — through the
  same owner-scoped context functions the LiveView center uses.
  Someone else's notification id answers 404, never 403: the API
  refuses to confirm that another user's notification exists.
  """

  use KammerWeb, :controller

  alias Kammer.Notifications
  alias KammerWeb.Api.Pagination
  alias KammerWeb.Api.Serializer
  alias KammerWeb.ApiError

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    {notifications, next_cursor} =
      Notifications.list_notifications_page(
        conn.assigns.current_scope.user,
        Pagination.decode(params["after"]),
        Pagination.limit(params)
      )

    json(conn, %{
      data: Enum.map(notifications, &Serializer.notification/1),
      next_cursor: Pagination.encode(next_cursor)
    })
  end

  @spec mark_read(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def mark_read(conn, %{"notification_id" => notification_id}) do
    case Notifications.mark_read(conn.assigns.current_scope.user, notification_id) do
      :ok -> json(conn, %{status: "read"})
      {:error, :not_found} -> ApiError.send(conn, :not_found, "Not found.")
    end
  end

  @spec mark_all_read(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def mark_all_read(conn, _params) do
    :ok = Notifications.mark_all_read(conn.assigns.current_scope.user)
    json(conn, %{status: "read"})
  end
end
