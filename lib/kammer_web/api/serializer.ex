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
  alias Kammer.Accounts.UserToken
  alias Kammer.Assignments.Assignment
  alias Kammer.Audit.AuditEvent
  alias Kammer.Availability.AvailabilityPoll
  alias Kammer.Communities.Community
  alias Kammer.Communities.CommunityMembership
  alias Kammer.Communities.CustomField
  alias Kammer.Communities.InstanceSettings
  alias Kammer.Decisions.Decision
  alias Kammer.Moderation.CommunityBan
  alias Kammer.Moderation.Report
  alias Kammer.Events.Event
  alias Kammer.Feed.Comment
  alias Kammer.Feed.Poll
  alias Kammer.Feed.Post
  alias Kammer.Feed.PostAttachment
  alias Kammer.Files.Folder
  alias Kammer.Files.StoredFile
  alias Kammer.Groups.Group
  alias Kammer.Groups.GroupJoinRequest
  alias Kammer.Groups.GroupMembership
  alias Kammer.Invitations.Invite
  alias Kammer.Legal
  alias Kammer.Markdown
  alias Kammer.Notifications.Notification
  alias Kammer.Validation

  @spec community(Community.t(), User.t() | nil, Authorization.relationship() | nil) :: map()
  def community(community, viewer \\ nil, relationship \\ nil)

  def community(%Community{} = community, viewer, relationship) do
    %{
      id: community.id,
      name: community.name,
      slug: community.slug,
      description: community.description,
      # Direct columns, always loaded, none secret: accent themes the
      # client, the rest let an admin's settings screen (issue #183)
      # read current values without a second shape. `viewer_can` still
      # gates whether the client shows the editing UI.
      accent_color: community.accent_color,
      default_locale: community.default_locale,
      listed_on_instance: community.listed_on_instance,
      require_real_names: community.require_real_names,
      my_role: relationship && relationship.community_role,
      viewer_can: community_capabilities(viewer, community, relationship)
    }
  end

  @spec group(Group.t(), User.t() | nil, Authorization.relationship() | nil) :: map()
  def group(group, viewer \\ nil, relationship \\ nil)

  def group(%Group{} = group, viewer, relationship) do
    capabilities = group_capabilities(viewer, group, relationship)

    %{
      id: group.id,
      name: group.name,
      slug: group.slug,
      description: group.description,
      visibility: group.visibility,
      join_policy: group.join_policy,
      features: group.features,
      sealed: group.sealed,
      archived: Group.archived?(group),
      my_role: relationship && relationship.group_role,
      viewer_can: capabilities,
      # Static facts about the group, not the viewer (issue #185 slice
      # B): whether an account-less guest could RSVP/comment/subscribe
      # here at all, so a client can decide whether to render those
      # forms without guessing from `visibility`/`archived`/`sealed`
      # itself or trying a request and handling the refusal. Computed
      # from the exact same `Authorization.can_guest_*?/1` the guest
      # request endpoints enforce, so it can't drift from what those
      # endpoints actually accept.
      guest_rsvp_allowed: Authorization.can_guest_rsvp?(group),
      guest_comment_allowed: Authorization.can_guest_comment?(group),
      guest_subscribe_allowed: Authorization.can_guest_subscribe?(group)
    }
    |> put_group_settings(group, capabilities)
  end

  # The group's editable settings (issue #259) are a manager-only
  # surface — the settings form pre-fills from them. They must NOT ride
  # the tokenless public group shape (`Serializer.group/1` from
  # `PublicController`), where emitting them would disclose a public
  # group's moderation posture (`approval_queue`) and file-retention
  # config to anonymous callers. Gate on `:manage_group` — the exact
  # capability the settings screen itself keys off — so the fields
  # appear for, and only for, a viewer who can actually edit them.
  defp put_group_settings(map, group, capabilities) do
    # `capabilities` is the string list `group_capabilities/3` emits (the
    # same one that lands in `viewer_can`), so match the string, not the
    # `:manage_group` atom.
    if "manage_group" in capabilities do
      Map.merge(map, %{
        posting_policy: group.posting_policy,
        comment_policy: group.comment_policy,
        approval_queue: group.approval_queue,
        version_retention: group.version_retention
      })
    else
      map
    end
  end

  @doc """
  `opts` accepts `public: true` (issue #185 slice B) to shape
  attachment URLs for the tokenless public surface
  (`/api/v1/public/files/...`, see `stored_file/2`) instead of the
  default Bearer-authenticated ones — the only wire difference between
  the public and authenticated post shapes. Every other field is
  identical; callers on the public path already pass `viewer`/
  `relationship` as `nil` since there is no signed-in actor.
  """
  @spec post(Post.t(), User.t() | nil, Authorization.relationship() | nil, keyword()) :: map()
  def post(post, viewer \\ nil, relationship \\ nil, opts \\ [])

  def post(%Post{} = post, viewer, relationship, opts) do
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
      attachments: attachments(post, opts),
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
  A stored file: metadata plus the API file URLs. Bearer-authorized
  `/api/v1/files/...` by default, like every other authenticated API
  route; pass `public: true` (issue #185 slice B) for the tokenless
  `/api/v1/public/files/...` twin instead — used only when shaping a
  post attachment for the public post-read surface, never for the
  upload endpoint's response (there is no anonymous upload).
  """
  @spec stored_file(StoredFile.t(), keyword()) :: map()
  def stored_file(%StoredFile{} = stored_file, opts \\ []) do
    base = if opts[:public], do: "/api/v1/public/files", else: "/api/v1/files"

    %{
      id: stored_file.id,
      filename: stored_file.filename,
      content_type: stored_file.content_type,
      byte_size: stored_file.byte_size,
      kind: stored_file.kind,
      width: stored_file.width,
      height: stored_file.height,
      url: "#{base}/#{stored_file.id}",
      thumbnail_url: if(stored_file.thumbnail_key, do: "#{base}/#{stored_file.id}/thumbnail"),
      download_url: "#{base}/#{stored_file.id}/download"
    }
  end

  @doc """
  A stored file as a feed attachment: the stored-file shape keyed by
  the attachment link (`id`/`position`), `stored_file_id` pointing at
  the file itself. `opts` is forwarded to `stored_file/2` (the
  `public: true` URL switch).
  """
  @spec attachment(PostAttachment.t(), keyword()) :: map()
  def attachment(%PostAttachment{stored_file: %StoredFile{} = file} = attachment, opts \\ []) do
    file
    |> stored_file(opts)
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
      # The API is the one choke point every client reads through —
      # never emit a location_url a raw <a href> couldn't safely
      # render (issue #247; rows predating the changeset validation).
      location_url: if(Validation.http_url?(event.location_url), do: event.location_url),
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

  ## Collaborative tools (issue #184): availability polls, assignments,
  ## and the decisions register — each per-group and feature-gated
  ## (ADR 0016). The `viewer_can` capability list is computed from the
  ## same pure `Authorization` decisions the contexts enforce; without a
  ## group + relationship (the caller didn't thread one) it stays empty.

  @doc """
  A date-finding poll (issue #39) with its candidate dates, each date's
  answers, and the viewer's own answer per date. `viewer_can` names the
  advisory actions the caller may take — `respond` while it's open and
  they may react; `manage` (close/convert) for the creator or a
  moderator.
  """
  @spec availability_poll(
          AvailabilityPoll.t(),
          User.t() | nil,
          Group.t() | nil,
          Authorization.relationship() | nil
        ) :: map()
  def availability_poll(poll, viewer \\ nil, group \\ nil, relationship \\ nil)

  def availability_poll(%AvailabilityPoll{} = poll, viewer, group, relationship) do
    %{
      id: poll.id,
      group_id: poll.group_id,
      title: poll.title,
      closed: AvailabilityPoll.closed?(poll),
      converted_event_id: poll.converted_event_id,
      created_at: poll.inserted_at,
      created_by: user_ref(poll.created_by_user),
      options: poll_options(poll, viewer),
      viewer_can: poll_capabilities(poll, viewer, group, relationship)
    }
  end

  @doc """
  An assignment (issue #17): its state, claimants, the discussion
  thread, and — for the caller — whether they hold a claim. `viewer_can`
  names the advisory actions: `claim`/`complete` while open, `reopen`
  while done, `comment`, and `manage` (edit/delete) for creator or
  moderator.
  """
  @spec assignment(
          Assignment.t(),
          User.t() | nil,
          Group.t() | nil,
          Authorization.relationship() | nil
        ) :: map()
  def assignment(assignment, viewer \\ nil, group \\ nil, relationship \\ nil)

  def assignment(%Assignment{} = assignment, viewer, group, relationship) do
    %{
      id: assignment.id,
      group_id: assignment.group_id,
      title: assignment.title,
      notes_markdown: assignment.notes_markdown,
      due_at: assignment.due_at,
      completed: Assignment.done?(assignment),
      completed_at: assignment.completed_at,
      completed_by: user_ref(assignment.completed_by_user),
      created_at: assignment.inserted_at,
      created_by: user_ref(assignment.created_by_user),
      claims: assignment_claims(assignment),
      claimed_by_me: claimed_by_me?(assignment, viewer),
      comment_count: if(is_list(assignment.comments), do: length(assignment.comments)),
      comments:
        if(is_list(assignment.comments),
          do: Enum.map(assignment.comments, &comment(&1, viewer)),
          else: []
        ),
      viewer_can: assignment_capabilities(assignment, viewer, group, relationship)
    }
  end

  @doc """
  A decisions-register entry (issue #43): the motion, its linked feed
  post, and the recorded outcome. `viewer_can` is threaded in by the
  caller (recording the outcome depends on the motion's post author, a
  read the caller already made), so this shape stays query-free.
  """
  @spec decision(Decision.t(), [String.t()]) :: map()
  def decision(decision, viewer_can \\ [])

  def decision(%Decision{} = decision, viewer_can) do
    %{
      id: decision.id,
      group_id: decision.group_id,
      post_id: decision.post_id,
      title: decision.title,
      outcome: decision.outcome,
      outcome_note: decision.outcome_note,
      decided: Decision.decided?(decision),
      decided_at: decision.decided_at,
      decided_by: user_ref(decision.decided_by_user),
      created_at: decision.inserted_at,
      viewer_can: viewer_can
    }
  end

  @doc """
  Global search results (SPEC §16): each section reuses the resource's
  own serializer, so the wire shape has one home. The context already
  narrowed to what the viewer may see; this only shapes.
  """
  @spec search_results(Kammer.Search.results(), User.t() | nil) :: map()
  def search_results(%{posts: posts, comments: comments, events: events, files: files}, viewer) do
    %{
      posts: Enum.map(posts, &post(&1, viewer)),
      comments: Enum.map(comments, &comment(&1, viewer)),
      events: Enum.map(events, &event(&1, nil, viewer)),
      files: Enum.map(files, &file(&1, viewer))
    }
  end

  defp poll_options(%AvailabilityPoll{options: options}, viewer) when is_list(options) do
    Enum.map(options, fn option ->
      %{
        id: option.id,
        starts_at: option.starts_at,
        position: option.position,
        responses: option_responses(option),
        my_answer: my_answer(option, viewer)
      }
    end)
  end

  defp poll_options(_poll, _viewer), do: []

  defp option_responses(%{responses: responses}) when is_list(responses),
    do:
      Enum.map(responses, fn response ->
        %{user: user_ref(response.user), answer: response.answer}
      end)

  defp option_responses(_option), do: []

  defp my_answer(%{responses: responses}, %User{id: viewer_id}) when is_list(responses),
    do:
      Enum.find_value(responses, fn response ->
        response.user_id == viewer_id && response.answer
      end)

  defp my_answer(_option, _viewer), do: nil

  defp poll_capabilities(_poll, _viewer, nil, _relationship), do: []
  defp poll_capabilities(_poll, _viewer, _group, nil), do: []

  defp poll_capabilities(%AvailabilityPoll{} = poll, viewer, %Group{} = group, relationship) do
    open? = not AvailabilityPoll.closed?(poll)

    capabilities([
      {"respond", open? and Authorization.can_react?(viewer, group, relationship)},
      {"manage",
       open? and
         Authorization.can_manage_own_resource?(
           viewer,
           poll.created_by_user_id,
           group,
           relationship
         )}
    ])
  end

  defp assignment_claims(%Assignment{claims: claims}) when is_list(claims),
    do: claims |> Enum.map(&user_ref(&1.user)) |> Enum.reject(&is_nil/1)

  defp assignment_claims(_assignment), do: []

  defp claimed_by_me?(%Assignment{claims: claims}, %User{id: viewer_id}) when is_list(claims),
    do: Enum.any?(claims, &(&1.user_id == viewer_id))

  defp claimed_by_me?(_assignment, _viewer), do: false

  defp assignment_capabilities(_assignment, _viewer, nil, _relationship), do: []
  defp assignment_capabilities(_assignment, _viewer, _group, nil), do: []

  defp assignment_capabilities(%Assignment{} = assignment, viewer, %Group{} = group, relationship) do
    done? = Assignment.done?(assignment)
    reactor? = Authorization.can_react?(viewer, group, relationship)

    capabilities([
      {"claim", not done? and reactor?},
      {"complete", not done? and reactor?},
      {"reopen", done? and reactor?},
      {"comment", Authorization.can?(viewer, :comment_in_group, group, relationship)},
      {"manage",
       Authorization.can_manage_own_resource?(
         viewer,
         assignment.created_by_user_id,
         group,
         relationship
       )}
    ])
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

  defp attachments(%Post{attachments: attachment_list}, opts) when is_list(attachment_list) do
    attachment_list
    |> Enum.filter(&match?(%PostAttachment{stored_file: %StoredFile{}}, &1))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(&attachment(&1, opts))
  end

  defp attachments(_post, _opts), do: []

  ## People (issue #182): invites, roster rows, memberships, profile,
  ## devices. Redaction (ADR 0020) happens in the contexts —
  ## `visible_contact_fields`, `list_visible_custom_fields` — the
  ## controller feeds the already-redacted pieces in; these only shape.

  @doc """
  An invite link as its managers see it (SPEC §3). `token` is the
  shareable secret — this shape only ever answers callers who hold
  `create_*_invite` on the target.
  """
  @spec invite(Invite.t()) :: map()
  def invite(%Invite{} = invite) do
    %{
      id: invite.id,
      token: invite.token,
      group_id: invite.group_id,
      invited_email: invite.invited_email,
      expires_at: invite.expires_at,
      max_uses: invite.max_uses,
      use_count: invite.use_count,
      revoked: invite.revoked_at != nil,
      created_at: invite.inserted_at
    }
  end

  @doc """
  What an invite landing page shows before acceptance: the target, not
  the invite's management fields — the token is the whole credential,
  so this is the API twin of the public `/invite/:token` page.
  """
  @spec invite_preview(Invite.t()) :: map()
  def invite_preview(%Invite{community: %Community{} = community} = invite) do
    %{
      token: invite.token,
      community: %{
        id: community.id,
        name: community.name,
        slug: community.slug,
        description: community.description,
        require_real_names: community.require_real_names
      },
      group: invite_group(invite)
    }
  end

  defp invite_group(%Invite{group: %Group{id: id, name: name, slug: slug}}),
    do: %{id: id, name: name, slug: slug}

  defp invite_group(_invite), do: nil

  @doc """
  A report in a moderation queue (issue #183). The subject is embedded
  so a moderator can triage without a second fetch — group-scoped by
  `group_id` (from the preloads `Moderation.list_open_reports/2`
  already carries), never a live join here.
  """
  @spec report(Report.t()) :: map()
  def report(%Report{} = report) do
    %{
      id: report.id,
      reason: report.reason,
      status: report.status,
      inserted_at: report.inserted_at,
      reporter: user_ref(report.reporter_user),
      subject: report_subject(report)
    }
  end

  @doc "A community email ban (issue #183). Community admins only."
  @spec community_ban(CommunityBan.t()) :: map()
  def community_ban(%CommunityBan{} = ban) do
    %{
      id: ban.id,
      email: ban.email,
      reason: ban.reason,
      inserted_at: ban.inserted_at,
      banned_by: user_ref(ban.banned_by_user)
    }
  end

  @doc """
  One append-only audit entry (issue #183). `summary` is the
  plain-language record written at action time; `actor` is `nil` for
  system-initiated actions.
  """
  @spec audit_event(AuditEvent.t()) :: map()
  def audit_event(%AuditEvent{} = event) do
    %{
      id: event.id,
      action: event.action,
      summary: event.summary,
      metadata: event.metadata,
      inserted_at: event.inserted_at,
      actor: user_ref(event.actor_user)
    }
  end

  @doc """
  Instance-level settings (issue #183) — the operator-editable subset,
  never the update-check bookkeeping columns.
  """
  @spec instance_settings(InstanceSettings.t()) :: map()
  def instance_settings(%InstanceSettings{} = settings) do
    %{
      instance_name: settings.instance_name,
      default_locale: settings.default_locale,
      community_creation_policy: settings.community_creation_policy,
      storage_policy: settings.storage_policy,
      content_minimized_emails: settings.content_minimized_emails
    }
  end

  defp user_ref(%User{id: id, display_name: name}), do: %{id: id, display_name: name}
  defp user_ref(_), do: nil

  defp report_subject(%Report{post: %Post{} = post}) do
    %{
      type: "post",
      id: post.id,
      group_id: post.group_id,
      author: author(post),
      body_markdown: post.body_markdown
    }
  end

  defp report_subject(%Report{comment: %Comment{} = comment}) do
    %{
      type: "comment",
      id: comment.id,
      group_id: comment_group_id(comment),
      author: comment_author(comment),
      body_markdown: comment.body_markdown
    }
  end

  defp report_subject(_report), do: nil

  # The group is read straight from the preloaded parent (post/event/
  # assignment) the report already carries — no query here.
  defp comment_group_id(%Comment{post: %Post{group_id: group_id}}), do: group_id
  defp comment_group_id(%Comment{event: %Event{group_id: group_id}}), do: group_id
  defp comment_group_id(%Comment{assignment: %{group_id: group_id}}), do: group_id
  defp comment_group_id(_comment), do: nil

  @doc """
  A community-defined profile field (ADR 0020) — the roster's columns
  and the profile form's inputs.
  """
  @spec custom_field(CustomField.t()) :: map()
  def custom_field(%CustomField{} = field) do
    %{
      id: field.id,
      label: field.label,
      field_type: field.field_type,
      options: field.options,
      required: field.required,
      visibility: field.visibility,
      position: field.position
    }
  end

  @doc """
  A member-directory row (SPEC §4). `contact` and
  `custom_field_values` arrive already redacted for the viewer's role
  (ADR 0020) — the controller runs the visibility predicates, this
  only shapes.
  """
  @spec member(CommunityMembership.t(), [{atom(), String.t()}], map()) :: map()
  def member(%CommunityMembership{user: %User{} = user} = membership, contact_fields, values) do
    %{
      user: member_user(user),
      role: membership.role,
      joined_at: membership.inserted_at,
      contact: Map.new(contact_fields),
      custom_field_values: values
    }
  end

  @doc """
  A group-membership row: who and with which role.
  """
  @spec group_member(GroupMembership.t()) :: map()
  def group_member(%GroupMembership{user: %User{} = user} = membership) do
    %{
      user: member_user(user),
      role: membership.role,
      joined_at: membership.inserted_at
    }
  end

  @doc """
  A pending request to join a group (SPEC §3, `request_approval`).
  """
  @spec join_request(GroupJoinRequest.t()) :: map()
  def join_request(%GroupJoinRequest{user: %User{} = user} = request) do
    %{
      id: request.id,
      user: member_user(user),
      message: request.message,
      requested_at: request.inserted_at
    }
  end

  defp member_user(%User{} = user) do
    %{
      id: user.id,
      display_name: user.display_name,
      bio: user.bio,
      pronouns: user.pronouns
    }
  end

  @doc """
  The caller's own account and base profile (SPEC §4) — email and the
  per-field contact visibilities included, because it is theirs.
  """
  @spec profile(User.t()) :: map()
  def profile(%User{} = user) do
    %{
      id: user.id,
      email: user.email,
      display_name: user.display_name,
      locale: user.locale,
      timezone: user.timezone,
      digest_frequency: user.digest_frequency,
      feed_sort: user.feed_sort,
      bio: user.bio,
      pronouns: user.pronouns,
      contact_phone: user.contact_phone,
      contact_phone_visibility: user.contact_phone_visibility,
      contact_email: user.contact_email,
      contact_email_visibility: user.contact_email_visibility,
      contact_note: user.contact_note,
      contact_note_visibility: user.contact_note_visibility
    }
  end

  @doc """
  One of the caller's revocable credentials (issue #174): a browser
  session or an API device token. `device_name` is the user agent for
  sessions and the client-chosen name for API devices; `current` marks
  the credential making this request.
  """
  @spec device(UserToken.t(), Ecto.UUID.t() | nil) :: map()
  def device(%UserToken{} = token, current_id \\ nil) do
    %{
      id: token.id,
      kind: if(token.context == "api-device", do: "api_device", else: "session"),
      device_name: token.user_agent,
      created_at: token.inserted_at,
      current: token.id == current_id
    }
  end

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
      {"join", Authorization.can?(viewer, :join_group, group, relationship)},
      {"request_to_join",
       Authorization.can?(viewer, :request_to_join_group, group, relationship)},
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

  @doc """
  A guest's full management inventory (issue #185): everything behind
  their signed management link — identity plus their RSVPs, signup
  claims, comments (with moderation state), and newsletter
  subscriptions. Mirrors what `GuestLive.Manage` renders. Expects the
  preloads `Guests.fetch_manage_state/1` supplies.
  """
  @spec guest_manage_state(map()) :: map()
  def guest_manage_state(%{
        identity: identity,
        rsvps: rsvps,
        claims: claims,
        comments: comments,
        subscriptions: subscriptions
      }) do
    %{
      identity: %{display_name: identity.display_name, email: identity.email},
      rsvps:
        Enum.map(rsvps, fn rsvp ->
          %{event_id: rsvp.event_id, event_title: rsvp.event.title, status: rsvp.status}
        end),
      claims:
        Enum.map(claims, fn claim ->
          %{claim_id: claim.id, slot_title: claim.slot.title, event_title: claim.slot.event.title}
        end),
      comments:
        Enum.map(comments, fn comment ->
          %{
            group_name: comment.post.group.name,
            body_markdown: comment.body_markdown,
            pending_approval: comment.pending_approval,
            removed: Comment.deleted?(comment)
          }
        end),
      subscriptions:
        Enum.map(subscriptions, fn subscription ->
          %{
            subscription_id: subscription.id,
            community_name: subscription.group.community.name,
            group_name: subscription.group.name,
            cadence: subscription.cadence
          }
        end)
    }
  end

  @doc """
  A public legal page (issue #185): the operator's text or the built-in
  template, both as authored markdown and server-rendered HTML, plus
  whether an operator has published their own version yet.
  """
  @spec legal_page(String.t()) :: map()
  def legal_page(key) do
    page = Legal.get_page(key)

    %{
      key: key,
      title: Legal.title(key),
      content_markdown: page.content_markdown,
      content_html: Markdown.to_html(page.content_markdown),
      published: Legal.published?(key)
    }
  end
end
