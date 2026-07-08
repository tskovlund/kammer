defmodule KammerWeb.GuestPaths do
  @moduledoc """
  Shared path resolution for guest-facing controllers: an event's
  community-scoped URL, falling back to the home page if the
  community somehow no longer exists.
  """

  use KammerWeb, :verified_routes

  alias Kammer.Communities.Community
  alias Kammer.Events.Event
  alias Kammer.Repo

  @spec event_path(Event.t()) :: String.t()
  def event_path(event) do
    case Repo.get(Community, event.community_id) do
      nil -> ~p"/"
      community -> ~p"/c/#{community.slug}/events/#{event.id}"
    end
  end
end
