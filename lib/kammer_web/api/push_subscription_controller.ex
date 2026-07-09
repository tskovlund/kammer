defmodule KammerWeb.Api.PushSubscriptionController do
  @moduledoc """
  Web Push subscriptions over the API (SPEC §1: VAPID; issue #30):
  the same register/remove the browser's `PushSubscribe` hook drives,
  taking the standard `PushSubscription.toJSON()` shape and keeping
  the context's upsert semantics (re-registering an endpoint is a
  no-op). Deletion is by endpoint URL — the only handle a push
  client keeps — and idempotent, always scoped to the device owner.
  """

  use KammerWeb, :controller

  alias Kammer.Notifications
  alias KammerWeb.ApiError

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    subscription_params = Map.take(params, ["endpoint", "keys"])

    case Notifications.register_push_subscription(
           conn.assigns.current_scope.user,
           subscription_params
         ) do
      {:ok, _subscription} ->
        conn
        |> put_status(201)
        |> json(%{status: "subscribed"})

      {:error, :invalid_subscription} ->
        ApiError.send(
          conn,
          :unprocessable,
          "A Web Push subscription requires endpoint and keys.p256dh/keys.auth."
        )

      error ->
        ApiError.from_result(conn, error)
    end
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"endpoint" => endpoint}) when is_binary(endpoint) do
    :ok = Notifications.delete_push_subscription(conn.assigns.current_scope.user, endpoint)
    json(conn, %{status: "deleted"})
  end

  def delete(conn, _params),
    do: ApiError.send(conn, :bad_request, "An endpoint query parameter is required.")
end
