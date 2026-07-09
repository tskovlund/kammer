defmodule KammerWeb.Api.FeedChannel do
  @moduledoc """
  A group's feed over Channels (ADR 0014): the channel topic is the
  exact PubSub topic `Kammer.Feed` broadcasts on (`feed:group:<id>`),
  so joining subscribes to the same events LiveViews react to. Join
  authorization is the same `:view_group` decision the group page
  makes; payloads are re-fetched per viewer through
  `Kammer.Feed.fetch_visible_post/3` and shaped by the REST
  serializer, so a broadcast can never show a subscriber more than the
  feed endpoint would.
  """

  use Phoenix.Channel

  alias Kammer.Authorization
  alias Kammer.Feed
  alias Kammer.Groups
  alias KammerWeb.Api.Serializer

  @impl Phoenix.Channel
  def join("feed:group:" <> group_id, _payload, socket) do
    case Groups.fetch_viewable_group_by_id(socket.assigns.current_user, group_id) do
      {:ok, group} ->
        # The subscriber and group are fixed for the channel's life, so
        # resolve the relationship once here and reuse it for every
        # pushed post's `viewer_can`.
        relationship = Authorization.relationship(socket.assigns.current_user, group)
        {:ok, socket |> assign(:group, group) |> assign(:relationship, relationship)}

      {:error, _not_viewable} ->
        # One answer for "doesn't exist" and "not yours to see" — the
        # same no-existence-oracle stance as the REST 404s.
        {:error, %{error: %{code: "not_found", message: "Not found."}}}
    end
  end

  @impl Phoenix.Channel
  def handle_info({Kammer.Feed, {:post_created, post_id}}, socket),
    do: push_visible_post(socket, "post_created", post_id)

  def handle_info({Kammer.Feed, {:post_updated, post_id}}, socket),
    do: push_visible_post(socket, "post_updated", post_id)

  def handle_info({Kammer.Feed, {:post_deleted, post_id}}, socket) do
    # Deliberately unconditional: hard deletes leave nothing to
    # re-fetch, and the payload is a bare id — a subscriber who never
    # saw the post learns only that some post ceased to exist.
    push(socket, "post_deleted", %{id: post_id})
    {:noreply, socket}
  end

  def handle_info({Kammer.Feed, _other_event}, socket), do: {:noreply, socket}

  defp push_visible_post(socket, event, post_id) do
    case Feed.fetch_visible_post(socket.assigns.current_user, socket.assigns.group, post_id) do
      # Same wire shape as the REST feed page — one serializer.
      {:ok, post} ->
        push(
          socket,
          event,
          Serializer.post(post, socket.assigns.current_user, socket.assigns.relationship)
        )

      {:error, :not_found} ->
        :ok
    end

    {:noreply, socket}
  end
end
