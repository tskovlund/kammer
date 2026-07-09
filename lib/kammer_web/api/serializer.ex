defmodule KammerWeb.Api.Serializer do
  @moduledoc """
  The API's single shaping layer (RFC 0001): flat objects, snake_case,
  UUID strings, UTC ISO 8601. One function per resource so the wire
  shape has exactly one home — the OpenAPI schemas mirror these.
  Markdown ships as authored (`*_markdown`); rendering is the client's
  job, exactly as LiveView renders it server-side.

  Viewer-dependent fields (`my_reactions`, `my_votes`,
  `my_acknowledged`) come from the same preloads the feed already
  carries — passing the viewer adds no queries, it only filters what
  is already loaded.

  The `viewer_can` capability list (issue #199) is the one field that
  reads authorization rather than data: it names the actions
  `Kammer.Authorization` would permit this viewer, so clients can hide
  controls they'd otherwise only be `403`ed on. It's computed from the
  pure `can?/4` decision core — the same rules the controllers enforce,
  so the signal can't drift from enforcement — and takes no database
  access here. Callers thread in the viewer's `relationship` (loaded
  once, e.g. per feed page) exactly as they already thread the viewer;
  without one the list is empty, so unknown rights read as "no special
  controls" rather than ever leaking one.
  """

  alias Kammer.Authorization
  alias Kammer.Accounts.User
  alias Kammer.Communities.Community
  alias Kammer.Events.Event
  alias Kammer.Feed.Comment
  alias Kammer.Feed.Poll
  alias Kammer.Feed.Post
  alias Kammer.Feed.PostAttachment
  alias Kammer.Files.Folder
  alias Kammer.Files.StoredFile
  alias Kammer.Groups.Group
  alias Kammer.Notifications.Notification

  @spec community(Community.t(), User.t() | nil, Authorization.relationship() | nil) :: map()
  def community(community, viewer \\ nil, relationship \\ nil)

  def community(%Community{} = community, viewer, relationship) do
    %{
      id: community.id,
      name: community.name,
      slug: community.slug,
      description: community.description,
      viewer_can: community_capabilities(viewer, community, relationship)
    }
  end

  @spec group(Group.t(), User.t() | nil, Authorization.relationship() | nil) :: map()
  def group(group, viewer \\ nil, relationship \\ nil)

  def group(%Group{} = group, viewer, relationship) do
    %{
      id: group.id,
      name: group.name,
      slug: group.slug,
      description: group.description,
      visibility: group.visibility,
      features: group.features,
      sealed: group.sealed,
      archived: Group.archived?(group),
      viewer_can: group_capabilities(viewer, group, relationship)
    }
  end

  @spec post(Post.t(), User.t() | nil, Authorization.relationship() | nil) :: map()
  def post(post, viewer \\ nil, relationship \\ nil)

  def post(%Post{} = post, viewer, relationship) do
    deleted? = Post.deleted?(post)

    %{
      id: post.id,
      group_id: post.group_id,
      author: author(post),
      body_markdown: unless(deleted?, do: post.body_markdown),
      deleted: deleted?,
      published_at: post.published_at,
      edited_at: post.edited_at,
      pending_approval: post.pending_approval,
      pinned: post.pinned_at != nil,
      acknowledgment_required: post.acknowledgment_required,
      acknowledged_count: acknowledged_count(post),
      my_acknowledged: my_acknowledged(post, viewer),
      comment_count: if(is_list(post.comments), do: length(post.comments)),
      reactions: reaction_counts(post.reactions),
      my_reactions: my_reactions(post.reactions, viewer),
      attachments: attachments(post),
      poll: poll(post.poll, viewer),
      viewer_can: post_capabilities(post, viewer, relationship),
      comments:
        if(is_list(post.comments),
          do: Enum.map(post.comments, &comment(&1, viewer)),
          else: []
        )
    }
  end

  @spec comment(Comment.t(), User.t() | nil) :: map()
  def comment(%Comment{} = comment, viewer \\ nil) do
    deleted? = comment.deleted_at != nil

    %{
      id: comment.id,
      parent_comment_id: comment.parent_comment_id,
      author: comment_author(comment),
      body_markdown: unless(deleted?, do: comment.body_markdown),
      deleted: deleted?,
      pending_approval: comment.pending_approval,
      inserted_at: comment.inserted_at,
      edited_at: comment.edited_at,
      reactions: reaction_counts(comment.reactions),
      my_reactions: my_reactions(comment.reactions, viewer)
    }
  end

  @doc """
  A poll with the viewer's current selection — the shape poll-vote
  responses return, and the `poll` field of a post.
  """
  @spec poll(Poll.t() | nil | Ecto.Association.NotLoaded.t(), User.t() | nil) :: map() | nil
  def poll(poll, viewer \\ nil)
  def poll(nil, _viewer), do: nil
  def poll(%Ecto.Association.NotLoaded{}, _viewer), do: nil

  def poll(poll, viewer) do
    %{
      id: poll.id,
      multiple_choice: poll.multiple_choice,
      anonymous: poll.anonymous,
      closes_at: poll.closes_at,
      my_votes: my_votes(poll, viewer),
      options:
        Enum.map(poll.options, fn option ->
          %{id: option.id, text: option.text, votes: length(option.votes)}
        end)
    }
  end

  @doc """
  A stored file: metadata plus the API file URLs (`/api/v1/files/...`,
  Bearer-authorized like every other API route). The upload endpoint
  returns this shape; its `id` is what create-post's `stored_file_ids`
  takes.
  """
  @spec stored_file(StoredFile.t()) :: map()
  def stored_file(%StoredFile{} = stored_file) do
    %{
      id: stored_file.id,
      filename: stored_file.filename,
      content_type: stored_file.content_type,
      byte_size: stored_file.byte_size,
      kind: stored_file.kind,
      width: stored_file.width,
      height: stored_file.height,
      url: "/api/v1/files/#{stored_file.id}",
      thumbnail_url:
        if(stored_file.thumbnail_key, do: "/api/v1/files/#{stored_file.id}/thumbnail"),
      download_url: "/api/v1/files/#{stored_file.id}/download"
    }
  end

  @doc """
  A stored file as a feed attachment: the stored-file shape keyed by
  the attachment link (`id`/`position`), `stored_file_id` pointing at
  the file itself.
  """
  @spec attachment(PostAttachment.t()) :: map()
  def attachment(%PostAttachment{stored_file: %StoredFile{} = file} = attachment) do
    file
    |> stored_file()
    |> Map.merge(%{id: attachment.id, stored_file_id: file.id, position: attachment.position})
  end

  @doc """
  A file-space folder (SPEC §7, ADR 0009): its placement and the two
  read/write preset overrides. `system` marks the auto-created folders
  (e.g. "Feed uploads") that can't be renamed or deleted.
  """
  @spec folder(Folder.t()) :: map()
  def folder(%Folder{} = folder) do
    %{
      id: folder.id,
      name: folder.name,
      parent_folder_id: folder.parent_folder_id,
      read_override: folder.read_override,
      write_override: folder.write_override,
      system: folder.system_key != nil
    }
  end

  @doc """
  A library file entry (ADR 0017): the current version's stored-file
  shape, plus its entry/folder placement, uploader, and — on detail —
  the full version history (newest first, `current` flagging the head).
  `mine` marks the caller's own uploads so the client can offer a delete
  affordance the context still enforces; `versions` is empty on listings.
  """
  @spec file(StoredFile.t(), User.t() | nil, [StoredFile.t()] | nil) :: map()
  def file(stored_file, viewer \\ nil, versions \\ nil)

  def file(%StoredFile{} = stored_file, viewer, versions) do
    current_id = current_version_id(versions)

    stored_file
    |> stored_file()
    |> Map.merge(%{
      file_entry_id: stored_file.file_entry_id,
      folder_id: stored_file.folder_id,
      version_seq: stored_file.version_seq,
      uploaded_at: stored_file.inserted_at,
      uploaded_by: uploader(stored_file),
      mine: mine?(stored_file, viewer),
      versions:
        if(is_list(versions),
          do: Enum.map(versions, &file_version(&1, current_id, viewer)),
          else: []
        )
    })
  end

  @doc """
  One stored version of a file entry (ADR 0017). `current` marks the
  version the entry currently points at; the byte URLs are the same
  Bearer-authorized routes every stored file exposes.
  """
  @spec file_version(StoredFile.t(), Ecto.UUID.t() | nil, User.t() | nil) :: map()
  def file_version(version, current_id \\ nil, viewer \\ nil)

  def file_version(%StoredFile{} = version, current_id, viewer) do
    %{
      id: version.id,
      filename: version.filename,
      content_type: version.content_type,
      byte_size: version.byte_size,
      kind: version.kind,
      version_seq: version.version_seq,
      uploaded_at: version.inserted_at,
      uploaded_by: uploader(version),
      mine: mine?(version, viewer),
      current: version.id == current_id,
      url: "/api/v1/files/#{version.id}",
      thumbnail_url: if(version.thumbnail_key, do: "/api/v1/files/#{version.id}/thumbnail"),
      download_url: "/api/v1/files/#{version.id}/download"
    }
  end

  # Versions come newest-first (desc version_seq), and an entry's current
  # version is always its newest surviving one — uploads set it, and a
  # deleted current repoints to the newest remaining — so the head is it.
  defp current_version_id([%StoredFile{id: id} | _rest]), do: id
  defp current_version_id(_versions), do: nil

  defp uploader(%StoredFile{uploader_user: %User{id: id, display_name: name}}),
    do: %{type: "user", id: id, display_name: name}

  defp uploader(_stored_file), do: nil

  defp mine?(%StoredFile{uploader_user_id: uploader_id}, %User{id: viewer_id}),
    do: uploader_id == viewer_id

  defp mine?(_stored_file, _viewer), do: false

  @spec event(Event.t(), Kammer.Events.EventRsvp.t() | nil, User.t() | nil) :: map()
  def event(%Event{} = event, my_rsvp \\ nil, viewer \\ nil) do
    %{
      id: event.id,
      group_id: event.group_id,
      group: event_group(event),
      series_id: event.series_id,
      title: event.title,
      description_markdown: event.description_markdown,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      all_day: event.all_day,
      timezone: event.timezone,
      location_name: event.location_name,
      location_url: event.location_url,
      cancelled: event.cancelled_at != nil,
      comments_locked: event.comment_locked_at != nil,
      rsvp_counts: rsvp_counts(event),
      my_rsvp: my_rsvp && my_rsvp.status,
      slots: slots(event),
      comments:
        if(is_list(event.comments),
          do: Enum.map(event.comments, &comment(&1, viewer)),
          else: []
        )
    }
  end

  @spec notification(Notification.t()) :: map()
  def notification(%Notification{} = notification) do
    %{
      id: notification.id,
      kind: notification.kind,
      read: notification.read_at != nil,
      read_at: notification.read_at,
      inserted_at: notification.inserted_at,
      actor: notification_actor(notification),
      community: notification_community(notification),
      group: notification_group(notification),
      post_id: notification.post_id,
      comment_id: notification.comment_id,
      event_id: notification.event_id
    }
  end

  # A group-authored post (no comment involved — comments always have a
  # human author) hides its human author by design, so the actor is the
  # group (#167) — same dispatch as `author/1` below. Requires the
  # notification's `:post` preloaded (the Notifications read paths do).
  defp notification_actor(%Notification{
         comment_id: nil,
         post: %Post{author_type: :group},
         group: group
       }) do
    case group do
      %Group{id: id, name: name} -> %{type: "group", id: id, display_name: name}
      _not_loaded -> nil
    end
  end

  defp notification_actor(%Notification{actor_user: %{id: id, display_name: name}}),
    do: %{type: "user", id: id, display_name: name}

  defp notification_actor(_notification), do: nil

  defp notification_community(%Notification{community: %Community{} = loaded}),
    do: community(loaded)

  defp notification_community(_notification), do: nil

  defp notification_group(%Notification{group: %Group{id: id, name: name, slug: slug}}),
    do: %{id: id, name: name, slug: slug}

  defp notification_group(_notification), do: nil

  defp author(%Post{author_type: :group, group: %Group{} = group}),
    do: %{type: "group", id: group.id, display_name: group.name}

  defp author(%Post{author_user: %{id: id, display_name: name}}),
    do: %{type: "user", id: id, display_name: name}

  defp author(_post), do: nil

  defp comment_author(%Comment{author_user: %{id: id, display_name: name}}),
    do: %{type: "user", id: id, display_name: name}

  defp comment_author(%Comment{guest_identity: %Kammer.Guests.GuestIdentity{} = guest}),
    do: %{type: "guest", id: guest.id, display_name: guest.display_name}

  defp comment_author(_comment), do: nil

  defp event_group(%Event{group: %Group{} = group}),
    do: %{id: group.id, name: group.name, slug: group.slug}

  defp event_group(_event), do: nil

  defp slots(%Event{slots: slot_list}) when is_list(slot_list) do
    Enum.map(slot_list, fn slot ->
      %{
        id: slot.id,
        title: slot.title,
        capacity: slot.capacity,
        taken: if(is_list(slot.claims), do: length(slot.claims), else: 0),
        claimants: if(is_list(slot.claims), do: Enum.map(slot.claims, &claimant/1), else: [])
      }
    end)
  end

  defp slots(_event), do: []

  defp claimant(%{user: %{id: id, display_name: name}}),
    do: %{type: "user", id: id, display_name: name}

  defp claimant(%{guest_identity: %Kammer.Guests.GuestIdentity{} = guest}),
    do: %{type: "guest", id: guest.id, display_name: guest.display_name}

  defp claimant(_claim), do: nil

  defp reaction_counts(reactions) when is_list(reactions) do
    reactions
    |> Enum.group_by(& &1.emoji)
    |> Map.new(fn {emoji, list} -> {emoji, length(list)} end)
  end

  defp reaction_counts(_not_loaded), do: %{}

  defp my_reactions(reactions, %User{id: viewer_id}) when is_list(reactions) do
    for reaction <- reactions, reaction.user_id == viewer_id, do: reaction.emoji
  end

  defp my_reactions(_reactions, _viewer), do: []

  defp my_votes(%{options: options}, %User{id: viewer_id}) when is_list(options) do
    for option <- options,
        is_list(option.votes),
        vote <- option.votes,
        vote.user_id == viewer_id,
        do: option.id
  end

  defp my_votes(_poll, _viewer), do: []

  defp acknowledged_count(%Post{acknowledgments: acknowledgments})
       when is_list(acknowledgments),
       do: length(acknowledgments)

  defp acknowledged_count(_post), do: 0

  defp my_acknowledged(%Post{acknowledgments: acknowledgments}, %User{id: viewer_id})
       when is_list(acknowledgments),
       do: Enum.any?(acknowledgments, &(&1.user_id == viewer_id))

  defp my_acknowledged(_post, _viewer), do: false

  defp attachments(%Post{attachments: attachment_list}) when is_list(attachment_list) do
    attachment_list
    |> Enum.filter(&match?(%PostAttachment{stored_file: %StoredFile{}}, &1))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(&attachment/1)
  end

  defp attachments(_post), do: []

  ## Viewer capabilities (issue #199)
  ##
  ## The action-oriented subset clients actually branch on — not every
  ## internal permission atom. Each entry maps to the exact same pure
  ## `Kammer.Authorization` decision the controllers enforce, so a
  ## capability is present here IFF the corresponding write would
  ## succeed. Without a relationship (the caller didn't load one) the
  ## list is empty rather than guessed.

  defp community_capabilities(_viewer, _community, nil), do: []

  defp community_capabilities(viewer, community, relationship) do
    capabilities([
      {"manage_community",
       Authorization.can?(viewer, :manage_community, community, relationship)},
      {"create_group", Authorization.can?(viewer, :create_group, community, relationship)},
      {"view_member_directory",
       Authorization.can?(viewer, :view_member_directory, community, relationship)}
    ])
  end

  defp group_capabilities(_viewer, _group, nil), do: []

  defp group_capabilities(viewer, group, relationship) do
    capabilities([
      {"post", Authorization.can?(viewer, :post_in_group, group, relationship)},
      {"moderate", Authorization.can?(viewer, :moderate_group, group, relationship)},
      {"manage_group", Authorization.can?(viewer, :manage_group, group, relationship)},
      {"manage_members", Authorization.can?(viewer, :approve_group_members, group, relationship)},
      {"create_event",
       Group.feature_enabled?(group, :events) and
         Authorization.can?(viewer, :post_in_group, group, relationship)},
      {"upload_file",
       Group.feature_enabled?(group, :files) and
         Authorization.can_write_folder?(viewer, group, [], relationship)}
    ])
  end

  defp post_capabilities(_post, _viewer, nil), do: []

  defp post_capabilities(%Post{group: %Group{} = group} = post, viewer, relationship) do
    capabilities([
      {"edit", Authorization.can_edit_post?(viewer, post, group, relationship)},
      {"delete",
       Authorization.can_soft_delete_post?(viewer, post, group, relationship) or
         Authorization.can_hard_delete_post?(viewer, post, group, relationship)},
      {"pin", Authorization.can_pin_post?(viewer, post, group, relationship)},
      {"moderate", Authorization.can?(viewer, :moderate_group, group, relationship)}
    ])
  end

  # A post without its group preloaded can't be reasoned about — leave
  # the capabilities empty rather than query for the group here.
  defp post_capabilities(_post, _viewer, _relationship), do: []

  defp capabilities(pairs), do: for({name, true} <- pairs, do: name)

  defp rsvp_counts(%Event{rsvps: rsvps}) when is_list(rsvps) do
    Map.merge(
      %{yes: 0, maybe: 0, no: 0},
      rsvps
      |> Enum.group_by(& &1.status)
      |> Map.new(fn {status, list} -> {status, length(list)} end)
    )
  end

  defp rsvp_counts(_event), do: %{yes: 0, maybe: 0, no: 0}
end
