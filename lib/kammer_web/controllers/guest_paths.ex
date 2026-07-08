defmodule KammerWeb.GuestPaths do
  @moduledoc """
  Shared path resolution for guest-facing controllers: an event's
  community-scoped URL, built from the event's preloaded `:community`
  association.
  """

  use KammerWeb, :verified_routes

  alias Kammer.Communities.Community
  alias Kammer.Events.Event

  @spec event_path(Event.t()) :: String.t()
  def event_path(%Event{community: %Community{} = community} = event) do
    ~p"/c/#{community.slug}/events/#{event.id}"
  end
end
