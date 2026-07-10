defmodule Kammer.Search do
  @moduledoc """
  Global search within a community (SPEC §10): Postgres full-text
  search over posts, comments, events, and files, filtered through
  `Authorization.listable_groups_query/2` — search results are a form
  of *surfacing*, so they follow listing visibility, not link
  reachability (a `public_link` group's content never surfaces to
  non-members). The invariant — search never returns what the viewer
  couldn't already see — is property-tested.

  Files additionally ride the folder-permission invariant (SPEC §7,
  ADR 0009): SQL does the loose group/community and full-text
  filtering, then each candidate is checked in Elixir against
  `Authorization.can_read_folder?/4` — the same decision function
  `Kammer.Files.list_files/3` uses — over an in-memory folder chain, so
  a file in an `admins_only` folder never surfaces to a non-admin
  regardless of its group's visibility.

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
  alias Kammer.Files
  alias Kammer.Files.Folder
  alias Kammer.Files.StoredFile
  alias Kammer.Groups.Group
  alias Kammer.Repo

  @per_section 10
  @file_candidate_limit 50

  @type results() :: %{
          posts: [Post.t()],
          comments: [Comment.t()],
          events: [Event.t()],
          files: [StoredFile.t()]
        }

  @doc """
  Searches the community for the viewer. Returns up to #{@per_section}
  hits per section, best matches first. Blank queries return empty
  sections.
  """
  @spec search(User.t() | nil, Community.t(), String.t()) :: results()
  def search(actor, %Community{} = community, query_string) do
    trimmed = String.trim(query_string || "")

    if trimmed == "" do
      empty_results()
    else
      group_ids_query =
        actor
        |> Authorization.listable_groups_query(community)
        |> select([group], group.id)

      %{
        posts: search_posts(group_ids_query, trimmed),
        comments: search_comments(group_ids_query, trimmed),
        events: search_events(group_ids_query, trimmed),
        files: search_files(actor, community, group_ids_query, trimmed)
      }
    end
  end

  defp empty_results, do: %{posts: [], comments: [], events: [], files: []}

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

  # Loose SQL filter (community/group membership of the candidate's
  # scope, plus full-text match) over-selects a candidate set; the
  # folder-permission invariant is then checked precisely in Elixir
  # below, since it depends on per-folder overrides SQL can't express
  # without a recursive CTE per row.
  defp search_files(actor, community, group_ids_query, query_string) do
    candidates =
      Repo.all(
        from(stored_file in StoredFile,
          where: stored_file.community_id == ^community.id,
          where: is_nil(stored_file.transient_expires_at),
          where:
            is_nil(stored_file.group_id) or stored_file.group_id in subquery(group_ids_query),
          where:
            fragment(
              "to_tsvector('simple', regexp_replace(coalesce(?, ''), '[._-]', ' ', 'g') || ' ' || coalesce(?, '')) @@ websearch_to_tsquery('simple', ?)",
              stored_file.filename,
              stored_file.extracted_text,
              ^query_string
            ),
          order_by: [
            desc:
              fragment(
                "ts_rank(to_tsvector('simple', regexp_replace(coalesce(?, ''), '[._-]', ' ', 'g') || ' ' || coalesce(?, '')), websearch_to_tsquery('simple', ?))",
                stored_file.filename,
                stored_file.extracted_text,
                ^query_string
              ),
            desc: stored_file.inserted_at
          ],
          limit: @file_candidate_limit,
          preload: [:group]
        )
        |> Files.current_versions_only()
      )

    if candidates == [] do
      []
    else
      folders_by_id = community |> Files.list_all_folders() |> Map.new(&{&1.id, &1})
      relationships = scope_relationships(actor, community, candidates)

      candidates
      |> Enum.filter(&file_readable?(actor, &1, folders_by_id, relationships))
      |> Enum.take(@per_section)
    end
  end

  # One relationship lookup per distinct scope among the candidates
  # (not per file) — cheap even though `Authorization.relationship/2`
  # hits the database.
  defp scope_relationships(actor, community, candidates) do
    groups = candidates |> Enum.map(& &1.group) |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.id)

    community_entry = {nil, {community, Authorization.relationship(actor, community)}}

    group_entries =
      Enum.map(groups, fn %Group{} = group ->
        {group.id, {group, Authorization.relationship(actor, group)}}
      end)

    Map.new([community_entry | group_entries])
  end

  defp file_readable?(actor, %StoredFile{} = stored_file, folders_by_id, relationships) do
    {scope, relationship} = Map.fetch!(relationships, stored_file.group_id)
    chain = folder_chain_from_map(stored_file.folder_id, folders_by_id)

    Authorization.can_read_folder?(actor, scope, chain, relationship)
  end

  defp folder_chain_from_map(nil, _folders_by_id), do: []

  defp folder_chain_from_map(folder_id, folders_by_id) do
    build_chain_from_map(Map.get(folders_by_id, folder_id), folders_by_id, Folder.maximum_depth())
  end

  defp build_chain_from_map(nil, _folders_by_id, _remaining), do: []
  defp build_chain_from_map(%Folder{} = folder, _folders_by_id, 0), do: [folder]

  defp build_chain_from_map(%Folder{parent_folder_id: nil} = folder, _folders_by_id, _remaining),
    do: [folder]

  defp build_chain_from_map(%Folder{} = folder, folders_by_id, remaining) do
    build_chain_from_map(
      Map.get(folders_by_id, folder.parent_folder_id),
      folders_by_id,
      remaining - 1
    ) ++
      [folder]
  end
end
