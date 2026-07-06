defmodule Kammer.Search do
  @moduledoc """
  Global search within a community (SPEC §16): Postgres full-text
  search over posts, comments, and events, filtered through
  `Authorization.listable_groups_query/2` — search results are a form
  of *surfacing*, so they follow listing visibility, not link
  reachability (a `public_link` group's content never surfaces to
  non-members). The invariant — search never returns what the viewer
  couldn't already see — is property-tested.

  File search is deliberately absent until it can ride the
  folder-permission invariant properly (tracked in #33, together with
  file text extraction).

  The 'simple' text-search configuration matches the GIN indexes:
  no language stemming, because instances mix Danish and English.
  """

  import Ecto.Query, warn: false

  alias Kammer.Accounts.User
  alias Kammer.Assignments.Assignment
  alias Kammer.Authorization
  alias Kammer.Communities.Community
  alias Kammer.Events.Event
  alias Kammer.Feed.Comment
  alias Kammer.Feed.Post
  alias Kammer.Repo

  @per_section 10

  @type results() :: %{posts: [Post.t()], comments: [Comment.t()], events: [Event.t()]}

  @doc """
  Searches the community for the viewer. Returns up to #{@per_section}
  hits per section, best matches first. Blank queries return empty
  sections.
  """
  @spec search(User.t() | nil, Community.t(), String.t()) :: results()
  def search(actor, %Community{} = community, query_string) do
    trimmed = String.trim(query_string || "")

    if trimmed == "" do
      %{posts: [], comments: [], events: []}
    else
      group_ids_query =
        actor
        |> Authorization.listable_groups_query(community)
        |> select([group], group.id)

      %{
        posts: search_posts(group_ids_query, trimmed),
        comments: search_comments(group_ids_query, trimmed),
        events: search_events(group_ids_query, trimmed)
      }
    end
  end

  # Only published, approved, undeleted posts — the same rules the feed
  # applies for a non-author viewer.
  defp search_posts(group_ids_query, query_string) do
    now = DateTime.utc_now(:second)

    Repo.all(
      from(post in Post,
        where: post.group_id in subquery(group_ids_query),
        where: is_nil(post.deleted_at),
        where: post.pending_approval == false,
        where: post.published_at <= ^now,
        where:
          fragment(
            "to_tsvector('simple', coalesce(?, '')) @@ websearch_to_tsquery('simple', ?)",
            post.body_markdown,
            ^query_string
          ),
        order_by: [
          desc:
            fragment(
              "ts_rank(to_tsvector('simple', coalesce(?, '')), websearch_to_tsquery('simple', ?))",
              post.body_markdown,
              ^query_string
            ),
          desc: post.published_at
        ],
        limit: @per_section,
        preload: [:author_user, :group]
      )
    )
  end

  # A comment surfaces only if its subject would: post comments follow
  # the post's feed rules, event and assignment comments follow the
  # feature gate of their group.
  defp search_comments(group_ids_query, query_string) do
    now = DateTime.utc_now(:second)

    Repo.all(
      from(comment in Comment,
        left_join: post in Post,
        on: comment.post_id == post.id,
        left_join: event in Event,
        on: comment.event_id == event.id,
        left_join: assignment in Assignment,
        on: comment.assignment_id == assignment.id,
        left_join: event_group in Kammer.Groups.Group,
        on: event.group_id == event_group.id,
        left_join: assignment_group in Kammer.Groups.Group,
        on: assignment.group_id == assignment_group.id,
        where:
          coalesce(post.group_id, coalesce(event.group_id, assignment.group_id)) in subquery(
            group_ids_query
          ),
        where: is_nil(comment.deleted_at),
        where: comment.pending_approval == false,
        where:
          is_nil(comment.post_id) or
            (is_nil(post.deleted_at) and post.pending_approval == false and
               post.published_at <= ^now),
        where: is_nil(comment.event_id) or fragment("'events' = ANY(?)", event_group.features),
        where:
          is_nil(comment.assignment_id) or
            fragment("'assignments' = ANY(?)", assignment_group.features),
        where:
          fragment(
            "to_tsvector('simple', coalesce(?, '')) @@ websearch_to_tsquery('simple', ?)",
            comment.body_markdown,
            ^query_string
          ),
        order_by: [
          desc:
            fragment(
              "ts_rank(to_tsvector('simple', coalesce(?, '')), websearch_to_tsquery('simple', ?))",
              comment.body_markdown,
              ^query_string
            ),
          desc: comment.inserted_at
        ],
        limit: @per_section,
        preload: [:author_user, post: :group, event: :group, assignment: :group]
      )
    )
  end

  defp search_events(group_ids_query, query_string) do
    Repo.all(
      from(event in Event,
        join: group in Kammer.Groups.Group,
        on: event.group_id == group.id,
        where: event.group_id in subquery(group_ids_query),
        where: fragment("'events' = ANY(?)", group.features),
        where:
          fragment(
            "to_tsvector('simple', coalesce(?, '') || ' ' || coalesce(?, '')) @@ websearch_to_tsquery('simple', ?)",
            event.title,
            event.description_markdown,
            ^query_string
          ),
        order_by: [
          desc:
            fragment(
              "ts_rank(to_tsvector('simple', coalesce(?, '') || ' ' || coalesce(?, '')), websearch_to_tsquery('simple', ?))",
              event.title,
              event.description_markdown,
              ^query_string
            ),
          desc: event.starts_at
        ],
        limit: @per_section,
        preload: [:group]
      )
    )
  end
end
