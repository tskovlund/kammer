defmodule KammerWeb.CommunityScope do
  @moduledoc """
  LiveView `on_mount` hooks for community-scoped routes (`/c/:community_slug`).

  Loads the active community, the actor's relationship to it (via
  `Kammer.Authorization`), the user's communities for the switcher, and
  their member groups for the sidebar. Anonymous visitors get the public
  view of communities that expose one.
  """

  use KammerWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Groups

  @doc """
  `on_mount` entry points:

    * `:assign_community` — loads community + relationship; anonymous and
      non-member actors are allowed through (public pages decide what to
      show).
    * `:require_member` — additionally halts unless the actor is a member
      of the community.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:assign_community, %{"community_slug" => slug}, _session, socket) do
    case Communities.get_community_by_slug(slug) do
      nil ->
        {:halt,
         socket
         |> put_flash(:error, gettext_not_found())
         |> redirect(to: ~p"/")}

      community ->
        {:cont, assign_community_context(socket, community)}
    end
  end

  def on_mount(:require_member, %{"community_slug" => slug}, _session, socket) do
    case Communities.get_community_by_slug(slug) do
      nil ->
        {:halt, socket |> put_flash(:error, gettext_not_found()) |> redirect(to: ~p"/")}

      community ->
        socket = assign_community_context(socket, community)

        if socket.assigns.community_relationship.community_role do
          {:cont, socket}
        else
          {:halt,
           socket
           |> put_flash(:error, gettext_not_found())
           |> redirect(to: ~p"/c/#{community.slug}")}
        end
    end
  end

  defp assign_community_context(socket, community) do
    current_user = current_user(socket)
    relationship = Authorization.relationship(current_user, community)

    socket
    |> assign(:active_community, community)
    |> assign(:community_relationship, relationship)
    |> assign(:member_communities, member_communities(current_user))
    |> assign(:member_groups, member_groups(current_user, relationship, community))
    |> assign(:unread_notifications, Kammer.Notifications.unread_count(current_user))
  end

  defp current_user(socket) do
    case socket.assigns[:current_scope] do
      %{user: user} -> user
      _no_scope -> nil
    end
  end

  defp member_communities(nil), do: []
  defp member_communities(user), do: Communities.list_user_communities(user)

  defp member_groups(nil, _relationship, _community), do: []

  defp member_groups(user, relationship, community) do
    if relationship.community_role, do: Groups.list_member_groups(user, community), else: []
  end

  defp gettext_not_found do
    Gettext.dgettext(KammerWeb.Gettext, "default", "Community not found.")
  end
end
