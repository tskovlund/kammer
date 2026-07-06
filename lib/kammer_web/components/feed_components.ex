defmodule KammerWeb.FeedComponents do
  @moduledoc """
  Feed rendering (SPEC §5, §21): quiet post cards — content is the
  interface. Markdown bodies, image/file attachments, live polls,
  reactions, one-level comment threads with collapse, acknowledgment
  state, and the moderation menu. All permission flags are computed by
  the LiveView via `Kammer.Authorization` and passed in — no checks here.
  """

  use Phoenix.Component
  use Gettext, backend: KammerWeb.Gettext
  use KammerWeb, :verified_routes

  import KammerWeb.CoreComponents
  import KammerWeb.KammerComponents, only: [user_avatar: 1]

  alias Kammer.Feed.Comment
  alias Kammer.Feed.Post
  alias Kammer.Feed.Reaction
  alias Phoenix.LiveView.JS

  @collapse_reply_threshold 3

  @doc """
  One post card. `permissions` is the map computed by the LiveView.
  """
  attr :post, Post, required: true
  attr :current_user, :map, default: nil
  attr :permissions, :map, required: true
  attr :group_name, :string, default: nil
  attr :new_since_last_visit, :boolean, default: false
  attr :guest_comment_allowed, :boolean, default: false

  @spec post_card(map()) :: Phoenix.LiveView.Rendered.t()
  def post_card(assigns) do
    ~H"""
    <article
      id={"post-#{@post.id}"}
      class={[
        "rounded-box border border-base-200 bg-base-100",
        @new_since_last_visit && "border-l-2 border-l-[var(--accent,#3E6B48)]"
      ]}
    >
      <div class="flex items-start gap-3 p-4 pb-2">
        <.user_avatar :if={@post.author_user} user={@post.author_user} />
        <div class="min-w-0 flex-1">
          <p class="flex flex-wrap items-center gap-x-2 text-sm">
            <span class="font-medium">{author_name(@post)}</span>
            <span :if={@group_name} class="text-base-content/50">· {@group_name}</span>
            <span class="text-base-content/50" title={DateTime.to_iso8601(@post.published_at)}>
              {relative_time(@post.published_at)}
            </span>
            <span :if={@post.edited_at} class="text-base-content/40">
              ({gettext("edited")})
            </span>
          </p>
          <p class="flex flex-wrap gap-1.5 pt-0.5">
            <span :if={Post.pinned?(@post)} class="badge badge-ghost badge-xs gap-1">
              <.icon name="hero-bookmark" class="size-3" /> {gettext("Pinned")}
            </span>
            <span
              :if={Post.scheduled?(@post, DateTime.utc_now())}
              class="badge badge-ghost badge-xs gap-1"
            >
              <.icon name="hero-clock" class="size-3" /> {gettext("Scheduled")}
            </span>
            <span :if={@post.pending_approval} class="badge badge-warning badge-xs">
              {gettext("Awaiting approval")}
            </span>
            <span :if={@post.acknowledgment_required} class="badge badge-ghost badge-xs gap-1">
              <.icon name="hero-check-circle" class="size-3" /> {gettext("Acknowledgment required")}
            </span>
          </p>
        </div>

        <div :if={@current_user} class="dropdown dropdown-end">
          <button type="button" tabindex="0" class="btn btn-ghost btn-xs btn-square">
            <.icon name="hero-ellipsis-horizontal" class="size-4" />
          </button>
          <ul
            tabindex="0"
            class="dropdown-content menu z-20 w-52 rounded-box border border-base-200 bg-base-100 p-1 text-sm shadow-sm"
          >
            <li :if={@permissions.approve && @post.pending_approval}>
              <button phx-click="approve_post" phx-value-id={@post.id}>
                {gettext("Approve post")}
              </button>
            </li>
            <li :if={@permissions.pin}>
              <button phx-click="toggle_pin" phx-value-id={@post.id}>
                {if Post.pinned?(@post), do: gettext("Unpin"), else: gettext("Pin")}
              </button>
            </li>
            <li :if={@permissions.lock_comments}>
              <button phx-click="toggle_comment_lock" phx-value-id={@post.id}>
                {if Post.comments_locked?(@post),
                  do: gettext("Unlock comments"),
                  else: gettext("Lock comments")}
              </button>
            </li>
            <li :if={@permissions.edit}>
              <button phx-click="start_edit" phx-value-id={@post.id}>{gettext("Edit")}</button>
            </li>
            <li :if={@permissions.soft_delete}>
              <button
                phx-click="soft_delete_post"
                phx-value-id={@post.id}
                data-confirm={gettext("Remove this post? A stub will remain in the thread.")}
              >
                {gettext("Remove")}
              </button>
            </li>
            <li :if={@permissions.hard_delete}>
              <button
                phx-click="hard_delete_post"
                phx-value-id={@post.id}
                data-confirm={gettext("Permanently delete this post and its comments?")}
                class="text-error"
              >
                {gettext("Delete permanently")}
              </button>
            </li>
            <li>
              <button
                id={"report-post-#{@post.id}"}
                phx-click="start_report"
                phx-value-type="post"
                phx-value-id={@post.id}
              >
                {gettext("Report")}
              </button>
            </li>
          </ul>
        </div>
      </div>

      <div class="px-4 pb-3">
        <%= if Post.deleted?(@post) do %>
          <p class="italic text-base-content/50">{gettext("This post was removed.")}</p>
        <% else %>
          <div class="prose prose-sm max-w-none dark:prose-invert">
            {Phoenix.HTML.raw(Kammer.Markdown.to_html(@post.body_markdown))}
          </div>

          <div :if={image_attachments(@post) != []} class="grid grid-cols-2 gap-2 pt-3 sm:grid-cols-3">
            <a
              :for={attachment <- image_attachments(@post)}
              href={~p"/files/#{attachment.stored_file_id}"}
              target="_blank"
              rel="noopener"
              class="block overflow-hidden rounded-field border border-base-200"
            >
              <img
                src={~p"/files/#{attachment.stored_file_id}/thumbnail"}
                alt={attachment.stored_file.filename}
                loading="lazy"
                class="aspect-square w-full object-cover"
              />
            </a>
          </div>

          <ul :if={file_attachments(@post) != []} class="space-y-1 pt-3">
            <li :for={attachment <- file_attachments(@post)}>
              <a
                href={~p"/files/#{attachment.stored_file_id}/download"}
                class="flex items-center gap-2 rounded-field border border-base-200 px-3 py-2 text-sm hover:bg-base-200"
              >
                <.icon name="hero-paper-clip" class="size-4 shrink-0 text-base-content/50" />
                <span class="truncate">{attachment.stored_file.filename}</span>
                <span class="ml-auto whitespace-nowrap text-xs text-base-content/50">
                  {format_bytes(attachment.stored_file.byte_size)}
                </span>
              </a>
            </li>
          </ul>

          <.poll_block :if={@post.poll} poll={@post.poll} current_user={@current_user} />

          <.acknowledgment_block
            :if={@post.acknowledgment_required}
            post={@post}
            current_user={@current_user}
            can_view_status={@permissions.view_acknowledgments}
          />
        <% end %>
      </div>

      <div class="border-t border-base-200 px-4 py-2">
        <.reaction_bar
          subject_type="post"
          subject_id={@post.id}
          reactions={@post.reactions}
          current_user={@current_user}
          can_react={@permissions.react}
        />
      </div>

      <.comment_thread
        post={@post}
        current_user={@current_user}
        can_comment={@permissions.comment and not Post.comments_locked?(@post)}
        can_react={@permissions.react}
        can_moderate={@permissions.hard_delete}
        guest_comment_allowed={@guest_comment_allowed and not Post.comments_locked?(@post)}
      />
    </article>
    """
  end

  attr :poll, :map, required: true
  attr :current_user, :map, default: nil

  defp poll_block(assigns) do
    total_votes =
      assigns.poll.options
      |> Enum.flat_map(& &1.votes)
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()
      |> length()

    my_option_ids =
      case assigns.current_user do
        nil ->
          MapSet.new()

        user ->
          assigns.poll.options
          |> Enum.filter(fn option -> Enum.any?(option.votes, &(&1.user_id == user.id)) end)
          |> Enum.map(& &1.id)
          |> MapSet.new()
      end

    closed? = Kammer.Feed.Poll.closed?(assigns.poll, DateTime.utc_now())

    assigns =
      assign(assigns, total_votes: total_votes, my_option_ids: my_option_ids, closed?: closed?)

    ~H"""
    <div class="mt-3 space-y-1.5 rounded-field border border-base-200 p-3">
      <button
        :for={option <- Enum.sort_by(@poll.options, & &1.position)}
        type="button"
        phx-click="vote_poll"
        phx-value-poll-id={@poll.id}
        phx-value-option-id={option.id}
        disabled={@closed? or is_nil(@current_user)}
        class={[
          "relative block w-full overflow-hidden rounded-field border px-3 py-2 text-left text-sm",
          MapSet.member?(@my_option_ids, option.id) && "border-[var(--accent,#3E6B48)]",
          !MapSet.member?(@my_option_ids, option.id) && "border-base-200"
        ]}
      >
        <span
          class="accent-soft absolute inset-y-0 left-0"
          style={"width: #{percentage(option, @total_votes)}%"}
        ></span>
        <span class="relative flex items-center justify-between gap-2">
          <span>{option.text}</span>
          <span class="text-xs text-base-content/60">
            {length(Enum.uniq_by(option.votes, & &1.user_id))}
          </span>
        </span>
      </button>
      <p class="pt-1 text-xs text-base-content/50">
        {ngettext("%{count} vote", "%{count} votes", @total_votes)}
        <span :if={@poll.anonymous}>· {gettext("anonymous")}</span>
        <span :if={@poll.multiple_choice}>· {gettext("multiple choice")}</span>
        <span :if={@closed?}>· {gettext("closed")}</span>
        <span :if={@poll.closes_at && !@closed?}>
          · {gettext("closes %{time}", time: relative_time(@poll.closes_at))}
        </span>
      </p>
    </div>
    """
  end

  defp percentage(_option, 0), do: 0

  defp percentage(option, total_votes) do
    voters = option.votes |> Enum.uniq_by(& &1.user_id) |> length()
    round(voters / total_votes * 100)
  end

  attr :post, Post, required: true
  attr :current_user, :map, default: nil
  attr :can_view_status, :boolean, default: false

  defp acknowledgment_block(assigns) do
    acknowledged? =
      assigns.current_user &&
        Enum.any?(assigns.post.acknowledgments, &(&1.user_id == assigns.current_user.id))

    assigns = assign(assigns, :acknowledged?, acknowledged?)

    ~H"""
    <div class="mt-3 flex flex-wrap items-center gap-3 rounded-field border border-base-200 p-3">
      <%= if @acknowledged? do %>
        <span class="flex items-center gap-1.5 text-sm font-medium text-success">
          <.icon name="hero-check-circle-solid" class="size-5" /> {gettext("Acknowledged")}
        </span>
      <% else %>
        <button
          :if={@current_user}
          phx-click="acknowledge"
          phx-value-id={@post.id}
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-check" class="size-4" /> {gettext("Acknowledge")}
        </button>
      <% end %>
      <span class="text-sm text-base-content/60">
        {ngettext(
          "%{count} acknowledgment",
          "%{count} acknowledgments",
          length(@post.acknowledgments)
        )}
      </span>
      <button
        :if={@can_view_status}
        phx-click="show_acknowledgment_status"
        phx-value-id={@post.id}
        class="link text-sm"
      >
        {gettext("Who's missing?")}
      </button>
    </div>
    """
  end

  attr :subject_type, :string, required: true
  attr :subject_id, :string, required: true
  attr :reactions, :list, default: []
  attr :current_user, :map, default: nil
  attr :can_react, :boolean, default: false

  defp reaction_bar(assigns) do
    grouped =
      assigns.reactions
      |> Enum.group_by(& &1.emoji)
      |> Enum.sort_by(fn {_emoji, list} -> -length(list) end)

    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <div class="flex flex-wrap items-center gap-1.5">
      <button
        :for={{emoji, reaction_list} <- @grouped}
        :if={@can_react}
        phx-click="toggle_reaction"
        phx-value-type={@subject_type}
        phx-value-id={@subject_id}
        phx-value-emoji={emoji}
        class={[
          "btn btn-ghost btn-xs gap-1 rounded-full border",
          mine?(reaction_list, @current_user) && "accent-soft border-[var(--accent,#3E6B48)]",
          !mine?(reaction_list, @current_user) && "border-base-200"
        ]}
      >
        <span>{emoji}</span>
        <span class="text-xs">{length(reaction_list)}</span>
      </button>
      <span
        :for={{emoji, reaction_list} <- @grouped}
        :if={!@can_react}
        class="btn btn-ghost btn-xs pointer-events-none gap-1 rounded-full border border-base-200"
      >
        <span>{emoji}</span>
        <span class="text-xs">{length(reaction_list)}</span>
      </span>

      <div :if={@can_react} class="dropdown dropdown-top">
        <button
          type="button"
          tabindex="0"
          class="btn btn-ghost btn-xs rounded-full"
          title={gettext("Add reaction")}
        >
          <.icon name="hero-face-smile" class="size-4" />
        </button>
        <div
          tabindex="0"
          class="dropdown-content z-20 flex gap-1 rounded-box border border-base-200 bg-base-100 p-2 shadow-sm"
        >
          <button
            :for={emoji <- Reaction.allowed_emoji()}
            phx-click={
              JS.push("toggle_reaction",
                value: %{type: @subject_type, id: @subject_id, emoji: emoji}
              )
            }
            class="btn btn-ghost btn-xs px-1"
          >
            {emoji}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp mine?(_reaction_list, nil), do: false

  defp mine?(reaction_list, current_user),
    do: Enum.any?(reaction_list, &(&1.user_id == current_user.id))

  attr :post, Post, required: true
  attr :current_user, :map, default: nil
  attr :can_comment, :boolean, default: false
  attr :can_react, :boolean, default: false
  attr :can_moderate, :boolean, default: false
  attr :guest_comment_allowed, :boolean, default: false

  defp comment_thread(assigns) do
    top_level =
      assigns.post.comments
      |> Enum.filter(&is_nil(&1.parent_comment_id))
      |> Enum.sort_by(& &1.inserted_at, DateTime)

    assigns = assign(assigns, :top_level, top_level)

    ~H"""
    <div
      :if={@top_level != [] or @can_comment or @guest_comment_allowed}
      class="border-t border-base-200 px-4 py-3"
    >
      <div :if={Post.comments_locked?(@post)} class="pb-2 text-xs text-base-content/50">
        <.icon name="hero-lock-closed" class="size-3.5" /> {gettext("Comments are locked.")}
      </div>

      <div :for={comment <- @top_level} class="space-y-2 pb-3">
        <.comment_item
          comment={comment}
          current_user={@current_user}
          can_react={@can_react}
          can_moderate={@can_moderate}
        />
        <.reply_list
          comment={comment}
          post={@post}
          current_user={@current_user}
          can_comment={@can_comment}
          can_react={@can_react}
          can_moderate={@can_moderate}
        />
      </div>

      <form :if={@can_comment} phx-submit="create_comment" class="flex items-start gap-2 pt-1">
        <input type="hidden" name="post_id" value={@post.id} />
        <textarea
          name="body_markdown"
          rows="1"
          required
          placeholder={gettext("Write a comment…")}
          class="textarea textarea-sm min-h-9 flex-1"
        ></textarea>
        <button type="submit" class="btn btn-primary btn-sm">{gettext("Reply")}</button>
      </form>

      <form
        :if={@guest_comment_allowed and is_nil(@current_user)}
        id={"guest-comment-form-#{@post.id}"}
        phx-submit="guest_comment"
        class="space-y-2 pt-1"
      >
        <input type="hidden" name="post_id" value={@post.id} />
        <p class="text-xs font-medium text-base-content/60">{gettext("Comment as a guest")}</p>
        <div class="flex flex-wrap gap-2">
          <input
            type="text"
            name="guest[display_name]"
            required
            placeholder={gettext("Your name")}
            class="input input-sm flex-1"
          />
          <input
            type="email"
            name="guest[email]"
            required
            placeholder={gettext("Email")}
            class="input input-sm flex-1"
          />
        </div>
        <div class="flex items-start gap-2">
          <textarea
            name="guest[body_markdown]"
            rows="1"
            required
            maxlength="2000"
            placeholder={gettext("Write a comment…")}
            class="textarea textarea-sm min-h-9 flex-1"
          ></textarea>
          <button type="submit" class="btn btn-primary btn-sm">{gettext("Send")}</button>
        </div>
        <p class="text-xs text-base-content/50">
          {gettext("We'll email you a confirmation link. A moderator approves guest comments.")}
        </p>
      </form>
    </div>
    """
  end

  attr :comment, Comment, required: true
  attr :post, Post, required: true
  attr :current_user, :map, default: nil
  attr :can_comment, :boolean, default: false
  attr :can_react, :boolean, default: false
  attr :can_moderate, :boolean, default: false

  defp reply_list(assigns) do
    replies = Enum.sort_by(assigns.comment.replies, & &1.inserted_at, DateTime)
    collapsed? = length(replies) > @collapse_reply_threshold

    assigns = assign(assigns, replies: replies, collapsed?: collapsed?)

    ~H"""
    <div class="ml-10 space-y-2 border-l border-base-200 pl-3">
      <details :if={@collapsed?}>
        <summary class="cursor-pointer text-xs text-base-content/60">
          {ngettext("Show %{count} reply", "Show %{count} replies", length(@replies))}
        </summary>
        <div class="space-y-2 pt-2">
          <.comment_item
            :for={reply <- @replies}
            comment={reply}
            current_user={@current_user}
            can_react={@can_react}
            can_moderate={@can_moderate}
          />
        </div>
      </details>
      <%= if !@collapsed? do %>
        <.comment_item
          :for={reply <- @replies}
          comment={reply}
          current_user={@current_user}
          can_react={@can_react}
          can_moderate={@can_moderate}
        />
      <% end %>

      <form :if={@can_comment} phx-submit="create_comment" class="flex items-start gap-2">
        <input type="hidden" name="post_id" value={@post.id} />
        <input type="hidden" name="parent_comment_id" value={@comment.id} />
        <textarea
          name="body_markdown"
          rows="1"
          required
          placeholder={gettext("Reply…")}
          class="textarea textarea-xs min-h-8 flex-1"
        ></textarea>
        <button type="submit" class="btn btn-ghost btn-xs">{gettext("Reply")}</button>
      </form>
    </div>
    """
  end

  attr :comment, Comment, required: true
  attr :current_user, :map, default: nil
  attr :can_react, :boolean, default: false
  attr :can_moderate, :boolean, default: false

  defp comment_item(assigns) do
    ~H"""
    <div class="flex items-start gap-2" id={"comment-#{@comment.id}"}>
      <.user_avatar
        :if={@comment.author_user}
        user={@comment.author_user}
        size_class="size-7"
        text_class="text-xs"
      />
      <div class="min-w-0 flex-1">
        <p class="text-xs text-base-content/60">
          <span class="font-medium text-base-content">{comment_author_name(@comment)}</span>
          <span :if={@comment.guest_identity_id} class="badge badge-ghost badge-xs align-middle">
            {gettext("Guest")}
          </span>
          {relative_time(@comment.inserted_at)}
          <span :if={@comment.edited_at}>({gettext("edited")})</span>
          <span :if={@comment.pending_approval} class="badge badge-warning badge-xs align-middle">
            {gettext("Awaiting approval")}
          </span>
        </p>
        <%= if Comment.deleted?(@comment) do %>
          <p class="text-sm italic text-base-content/50">{gettext("This comment was removed.")}</p>
        <% else %>
          <div class="prose prose-sm max-w-none dark:prose-invert">
            {Phoenix.HTML.raw(Kammer.Markdown.to_html(@comment.body_markdown))}
          </div>
          <.reaction_bar
            subject_type="comment"
            subject_id={@comment.id}
            reactions={@comment.reactions}
            current_user={@current_user}
            can_react={@can_react}
          />
          <div :if={@comment.pending_approval and @can_moderate} class="flex gap-2 pt-1">
            <button
              phx-click="approve_guest_comment"
              phx-value-id={@comment.id}
              class="btn btn-primary btn-xs"
              id={"approve-comment-#{@comment.id}"}
            >
              {gettext("Approve")}
            </button>
            <button
              phx-click="reject_guest_comment"
              phx-value-id={@comment.id}
              data-confirm={gettext("Reject and delete this comment?")}
              class="btn btn-ghost btn-xs text-error"
              id={"reject-comment-#{@comment.id}"}
            >
              {gettext("Reject")}
            </button>
          </div>
        <% end %>
      </div>
      <button
        :if={@current_user && !Comment.deleted?(@comment)}
        id={"report-comment-#{@comment.id}"}
        phx-click="start_report"
        phx-value-type="comment"
        phx-value-id={@comment.id}
        class="btn btn-ghost btn-xs btn-square opacity-40 hover:opacity-100"
        title={gettext("Report")}
      >
        <.icon name="hero-flag" class="size-3.5" />
      </button>
      <button
        :if={
          @current_user &&
            (@can_moderate or
               (@current_user.id == @comment.author_user_id && !Comment.deleted?(@comment)))
        }
        phx-click="delete_comment"
        phx-value-id={@comment.id}
        data-confirm={gettext("Remove this comment?")}
        class="btn btn-ghost btn-xs btn-square opacity-40 hover:opacity-100"
        title={gettext("Remove")}
      >
        <.icon name="hero-trash" class="size-3.5" />
      </button>
    </div>
    """
  end

  defp comment_author_name(%Comment{author_user: %{display_name: name}}) when is_binary(name),
    do: name

  defp comment_author_name(%Comment{} = comment) do
    if Ecto.assoc_loaded?(comment.guest_identity) and comment.guest_identity do
      comment.guest_identity.display_name
    else
      gettext("Deleted user")
    end
  end

  defp author_name(%Post{author_type: :group} = post) do
    if Ecto.assoc_loaded?(post.group) and post.group do
      post.group.name
    else
      gettext("The group")
    end
  end

  defp author_name(%Post{author_user: nil}), do: gettext("Deleted user")
  defp author_name(%Post{author_user: author}), do: author.display_name

  defp image_attachments(post) do
    post.attachments
    |> Enum.filter(&(&1.stored_file && &1.stored_file.kind == :image))
    |> Enum.sort_by(& &1.position)
  end

  defp file_attachments(post) do
    post.attachments
    |> Enum.filter(&(&1.stored_file && &1.stored_file.kind == :file))
    |> Enum.sort_by(& &1.position)
  end

  @doc """
  Short relative timestamp for feed items.
  """
  @spec relative_time(DateTime.t()) :: String.t()
  def relative_time(%DateTime{} = datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      seconds < 0 -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
      seconds < 60 -> gettext("just now")
      seconds < 3600 -> gettext("%{count}m ago", count: div(seconds, 60))
      seconds < 86_400 -> gettext("%{count}h ago", count: div(seconds, 3600))
      seconds < 7 * 86_400 -> gettext("%{count}d ago", count: div(seconds, 86_400))
      true -> Calendar.strftime(datetime, "%Y-%m-%d")
    end
  end

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes) when bytes >= 1024, do: "#{div(bytes, 1024)} kB"
  defp format_bytes(bytes), do: "#{bytes} B"
end
