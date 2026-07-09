defmodule KammerWeb.Api.HomeController do
  @moduledoc """
  The merged Home over the API (ADR 0015): the same read-only lens the
  start page shows — upcoming events and recent activity across all the
  device owner's communities, labeled for client-side display. This is
  the endpoint the multi-instance client's landing screen is built on.
  """

  use KammerWeb, :controller

  alias Kammer.Authorization
  alias Kammer.Home
  alias KammerWeb.Api.Serializer

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    user = conn.assigns.current_scope.user

    json(conn, %{
      upcoming_events:
        Enum.map(Home.upcoming_events(user), fn event ->
          # `group` is already on the serialized event; only `community`
          # (not preloaded by the serializer) is added for merged-Home
          # labeling.
          event
          |> Serializer.event()
          |> Map.put(:community, Serializer.community(event.group.community))
        end),
      recent_activity:
        Enum.map(Home.recent_activity(user), fn post ->
          # Home aggregates across groups, so each post's `viewer_can`
          # needs its own group relationship.
          post
          |> Serializer.post(user, Authorization.relationship(user, post.group))
          |> Map.put(:community, Serializer.community(post.group.community))
          |> Map.put(:group, %{id: post.group.id, name: post.group.name, slug: post.group.slug})
        end)
    })
  end
end
