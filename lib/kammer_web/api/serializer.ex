defmodule KammerWeb.Api.Serializer do
  @moduledoc """
  The API's single shaping layer (RFC 0001): flat objects, snake_case,
  UUID strings, UTC ISO 8601. One function per resource so the wire
  shape has exactly one home — the OpenAPI schemas mirror these.
  Markdown ships as authored (`*_markdown`); rendering is the client's
  job, exactly as LiveView renders it server-side.
  """

  alias Kammer.Communities.Community
  alias Kammer.Events.Event
  alias Kammer.Feed.Comment
  alias Kammer.Feed.Post
  alias Kammer.Groups.Group
  alias Kammer.Notifications.Notification

  @spec community(Community.t()) :: map()
  def community(%Community{} = community) do
    %{
      id: community.id,
      name: community.name,
      slug: community.slug,
      description: community.description
    }
  end

  @spec group(Group.t()) :: map()
  def group(%Group{} = group) do
    %{
      id: group.id,
      name: group.name,
      slug: group.slug,
      description: group.description,
      visibility: group.visibility,
      features: group.features,
      sealed: group.sealed,
      archived: Group.archived?(group)
    }
  end

  @spec post(Post.t()) :: map()
  def post(%Post{} = post) do
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
      comment_count: if(is_list(post.comments), do: length(post.comments)),
      reactions: reaction_counts(post.reactions),
      poll: poll(post.poll),
      comments: if(is_list(post.comments), do: Enum.map(post.comments, &comment/1), else: [])
    }
  end

  @spec comment(Comment.t()) :: map()
  def comment(%Comment{} = comment) do
    deleted? = comment.deleted_at != nil

    %{
      id: comment.id,
      parent_comment_id: comment.parent_comment_id,
      author: comment_author(comment),
      body_markdown: unless(deleted?, do: comment.body_markdown),
      deleted: deleted?,
      pending_approval: comment.pending_approval,
      inserted_at: comment.inserted_at
    }
  end

  @spec event(Event.t(), Kammer.Events.EventRsvp.t() | nil) :: map()
  def event(%Event{} = event, my_rsvp \\ nil) do
    %{
      id: event.id,
      group_id: event.group_id,
      title: event.title,
      description_markdown: event.description_markdown,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      all_day: event.all_day,
      timezone: event.timezone,
      location_name: event.location_name,
      location_url: event.location_url,
      rsvp_counts: rsvp_counts(event),
      my_rsvp: my_rsvp && my_rsvp.status,
      slots: slots(event)
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

  defp poll(nil), do: nil
  defp poll(%Ecto.Association.NotLoaded{}), do: nil

  defp poll(poll) do
    %{
      id: poll.id,
      multiple_choice: poll.multiple_choice,
      anonymous: poll.anonymous,
      closes_at: poll.closes_at,
      options:
        Enum.map(poll.options, fn option ->
          %{id: option.id, text: option.text, votes: length(option.votes)}
        end)
    }
  end

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
