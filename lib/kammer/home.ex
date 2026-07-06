defmodule Kammer.Home do
  @moduledoc """
  The cross-community Home (ADR 0015): one merged, strictly
  chronological view of everything the user belongs to — upcoming
  events and recent activity across all their groups in all their
  communities. A lens, not a place: every item shown is one the user
  could already reach by navigating, so authorization is untouched —
  membership *is* the visibility proof. Honors each membership's
  `show_in_home` flag (default on, sealed groups included — owner
  decision) and the per-group feature toggles.

  Plain union queries by design: no denormalized timeline until real
  usage proves them insufficient.
  """

  import Ecto.Query

  alias Kammer.Accounts.User
  alias Kammer.Events.Event
  alias Kammer.Feed.Post
  alias Kammer.Groups.GroupMembership
  alias Kammer.Repo

  @doc """
  Upcoming events across the user's Home-visible groups, soonest first.
  """
  @spec upcoming_events(User.t(), pos_integer()) :: [Event.t()]
  def upcoming_events(%User{} = user, limit \\ 8) do
    now = DateTime.utc_now(:second)

    Repo.all(
      from(event in Event,
        join: membership in GroupMembership,
        on: membership.group_id == event.group_id,
        join: group in assoc(event, :group),
        where: membership.user_id == ^user.id,
        where: membership.show_in_home,
        where: fragment("'events' = ANY(?)", group.features),
        where: is_nil(group.archived_at),
        where: event.starts_at >= ^now or event.ends_at >= ^now,
        order_by: [asc: event.starts_at],
        limit: ^limit,
        preload: [group: {group, :community}]
      )
    )
  end

  @doc """
  Recent posts across the user's Home-visible groups, newest first
  (strictly chronological — the no-algorithm stance applies doubly on
  a merged surface).
  """
  @spec recent_activity(User.t(), pos_integer()) :: [Post.t()]
  def recent_activity(%User{} = user, limit \\ 15) do
    now = DateTime.utc_now(:second)

    Repo.all(
      from(post in Post,
        join: membership in GroupMembership,
        on: membership.group_id == post.group_id,
        join: group in assoc(post, :group),
        where: membership.user_id == ^user.id,
        where: membership.show_in_home,
        where: is_nil(group.archived_at),
        where: post.published_at <= ^now,
        where: post.pending_approval == false,
        where: is_nil(post.deleted_at),
        order_by: [desc: post.published_at, desc: post.id],
        limit: ^limit,
        preload: [:author_user, group: {group, :community}]
      )
    )
  end
end
