defmodule KammerWeb.GroupLive.Show do
  @moduledoc """
  Group page: the live feed (SPEC §5) — composer with Markdown, images
  and file attachments (incl. transient), polls, scheduling,
  acknowledgment-required posts, post-as-group — plus membership actions
  and members. Every decision the page renders passed
  `Kammer.Authorization`.
  """

  use KammerWeb, :live_view

  import KammerWeb.FeedComponents
  import KammerWeb.KammerComponents

  alias Kammer.Authorization
  alias Kammer.Feed
  alias Kammer.Files
  alias Kammer.Groups
  alias Kammer.Groups.Group
  alias KammerWeb.FeedEventHandlers

  @feed_events ~w(toggle_reaction create_comment delete_comment vote_poll acknowledge
                  show_acknowledgment_status toggle_pin toggle_comment_lock approve_post
                  soft_delete_post hard_delete_post approve_guest_comment reject_guest_comment)

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_community={member_of_community?(@community_relationship) && @active_community}
      member_communities={@member_communities}
      member_groups={@member_groups}
      community_relationship={@community_relationship}
      unread_notifications={@unread_notifications}
      current_tab={:groups}
    >
      <.header>
        {@group.name}
        <:subtitle>
          <span class="flex flex-wrap items-center gap-1.5">
            <.visibility_badge visibility={@group.visibility} />
            <span :if={@group.sealed} class="badge badge-ghost badge-sm">{gettext("Sealed")}</span>
            <span :if={Group.archived?(@group)} class="badge badge-warning badge-sm">
              {gettext("Archived")}
            </span>
            <span class="text-base-content/50">
              · {ngettext("%{count} member", "%{count} members", length(@members))}
            </span>
          </span>
        </:subtitle>
        <:actions>
          <.link
            :if={
              (@membership || @permissions.manage) &&
                Kammer.Groups.Group.feature_enabled?(@group, :files)
            }
            navigate={~p"/c/#{@active_community.slug}/g/#{@group.slug}/files"}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-folder" class="size-4" /> {gettext("Files")}
          </.link>
          <.link
            :if={@permissions.post && Kammer.Groups.Group.feature_enabled?(@group, :availability)}
            navigate={~p"/c/#{@active_community.slug}/g/#{@group.slug}/availability/new"}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-calendar-date-range" class="size-4" /> {gettext("Find a date")}
          </.link>
          <.link
            :if={@permissions.manage}
            navigate={~p"/c/#{@active_community.slug}/g/#{@group.slug}/settings"}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-cog-6-tooth" class="size-4" /> {gettext("Settings")}
          </.link>
        </:actions>
      </.header>

      <p :if={@group.description} class="text-base-content/80">{@group.description}</p>

      <div class="flex flex-wrap gap-2">
        <.button :if={@permissions.join} phx-click="join" class="btn btn-primary btn-sm">
          {gettext("Join group")}
        </.button>
        <.button
          :if={@permissions.request_to_join and not @pending_request?}
          phx-click="request_to_join"
          class="btn btn-primary btn-sm"
        >
          {gettext("Request to join")}
        </.button>
        <span :if={@pending_request?} class="badge badge-ghost">
          {gettext("Join request pending")}
        </span>
        <.button
          :if={@membership && @membership.role != :owner}
          phx-click="leave"
          data-confirm={gettext("Leave this group?")}
          class="btn btn-ghost btn-sm"
        >
          {gettext("Leave group")}
        </.button>

        <label
          :if={@membership}
          class="ml-auto flex cursor-pointer items-center gap-1.5 text-sm text-base-content/60"
          title={gettext("Show this group's activity on your Home screen")}
        >
          <input
            type="checkbox"
            id="show-in-home-toggle"
            checked={@membership.show_in_home}
            phx-click="toggle_show_in_home"
            class="toggle toggle-xs"
          />
          {gettext("Show in Home")}
        </label>

        <form
          :if={@membership}
          id="notification-level-form"
          phx-change="set_notification_level"
        >
          <label class="flex items-center gap-1.5 text-sm text-base-content/60">
            <.icon name="hero-bell" class="size-4" />
            <select name="level" class="select select-xs">
              <option
                :for={{value, label} <- notification_level_options()}
                value={value}
                selected={@notification_level == value}
              >
                {label}
              </option>
            </select>
          </label>
        </form>
      </div>

      <%!-- Composer --%>
      <section :if={@permissions.post} class="rounded-box border border-base-200 p-4">
        <.form
          for={@composer_form}
          id="composer_form"
          phx-submit="create_post"
          phx-change="validate_post"
        >
          <textarea
            id="composer_body"
            name="post[body_markdown]"
            rows="3"
            required
            placeholder={gettext("Write something… Markdown works.")}
            class="textarea w-full"
          >{@composer_form[:body_markdown].value}</textarea>

          <div class="flex flex-wrap items-center gap-3 pt-2 text-sm">
            <label class="flex cursor-pointer items-center gap-1.5">
              <input
                type="checkbox"
                name="post[acknowledgment_required]"
                value="true"
                checked={@composer_form[:acknowledgment_required].value == "true"}
                class="checkbox checkbox-xs"
              />
              {gettext("Requires acknowledgment")}
            </label>
            <label :if={@permissions.post_as_group} class="flex cursor-pointer items-center gap-1.5">
              <input
                type="checkbox"
                name="post[author_type]"
                value="group"
                checked={@composer_form[:author_type].value == "group"}
                class="checkbox checkbox-xs"
              />
              {gettext("Post as %{group}", group: @group.name)}
            </label>
            <label class="flex items-center gap-1.5">
              {gettext("Schedule")}
              <input
                type="datetime-local"
                name="post[scheduled_for]"
                value={@composer_form[:scheduled_for].value}
                class="input input-xs"
              />
            </label>
            <button
              type="button"
              phx-click="toggle_poll_builder"
              class={["btn btn-ghost btn-xs", @show_poll_builder && "btn-active"]}
            >
              <.icon name="hero-chart-bar" class="size-4" /> {gettext("Poll")}
            </button>
            <label class="btn btn-ghost btn-xs">
              <.icon name="hero-paper-clip" class="size-4" /> {gettext("Attach")}
              <.live_file_input upload={@uploads.attachments} class="hidden" />
            </label>
          </div>

          <div
            :if={@show_poll_builder}
            class="mt-3 space-y-2 rounded-field border border-base-200 p-3"
          >
            <p class="text-sm font-medium">{gettext("Poll")}</p>
            <input
              :for={index <- 0..(@poll_option_count - 1)}
              type="text"
              name={"post[poll][options][#{index}][text]"}
              value={poll_param(@composer_form, ["options", Integer.to_string(index), "text"])}
              placeholder={gettext("Option %{number}", number: index + 1)}
              class="input input-sm w-full"
            />
            <div class="flex flex-wrap items-center gap-3 text-sm">
              <button type="button" phx-click="add_poll_option" class="btn btn-ghost btn-xs">
                <.icon name="hero-plus" class="size-3.5" /> {gettext("Add option")}
              </button>
              <label class="flex cursor-pointer items-center gap-1.5">
                <input
                  type="checkbox"
                  name="post[poll][multiple_choice]"
                  value="true"
                  checked={poll_param(@composer_form, ["multiple_choice"]) == "true"}
                  class="checkbox checkbox-xs"
                />
                {gettext("Multiple choice")}
              </label>
              <label class="flex cursor-pointer items-center gap-1.5">
                <input
                  type="checkbox"
                  name="post[poll][anonymous]"
                  value="true"
                  checked={poll_param(@composer_form, ["anonymous"]) == "true"}
                  class="checkbox checkbox-xs"
                />
                {gettext("Anonymous votes")}
              </label>
              <label class="flex items-center gap-1.5">
                {gettext("Closes")}
                <input
                  type="datetime-local"
                  name="post[poll][closes_for]"
                  value={poll_param(@composer_form, ["closes_for"])}
                  class="input input-xs"
                />
              </label>
            </div>
          </div>

          <div :if={@uploads.attachments.entries != []} class="mt-3 space-y-1">
            <div
              :for={entry <- @uploads.attachments.entries}
              class="flex items-center gap-2 rounded-field border border-base-200 px-3 py-1.5 text-sm"
            >
              <.icon name="hero-paper-clip" class="size-4 text-base-content/50" />
              <span class="truncate">{entry.client_name}</span>
              <progress :if={!entry.done?} value={entry.progress} max="100" class="progress w-20"></progress>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="btn btn-ghost btn-xs btn-square ml-auto"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
              <p :for={error <- upload_errors(@uploads.attachments, entry)} class="text-xs text-error">
                {upload_error_message(error)}
              </p>
            </div>
            <label class="flex cursor-pointer items-center gap-1.5 pt-1 text-sm">
              <input
                type="checkbox"
                name="post[transient]"
                value="true"
                checked={@composer_form[:transient].value == "true"}
                class="checkbox checkbox-xs"
              />
              {gettext("Transient attachments (no file-space home, auto-delete after 30 days)")}
            </label>
          </div>

          <div class="pt-3">
            <.button variant="primary" phx-disable-with={gettext("Posting...")}>
              {gettext("Post")}
            </.button>
          </div>
        </.form>
      </section>

      <%!-- Feed --%>
      <section class="space-y-3 pt-2" id="group-feed">
        <div :for={post <- @posts}>
          <div
            :if={@first_new_post_id == post.id}
            class="flex items-center gap-2 py-1 text-xs font-medium text-[var(--accent,#3E6B48)]"
          >
            <span class="h-px flex-1 bg-[var(--accent,#3E6B48)]/40"></span>
            {gettext("New since your last visit")}
            <span class="h-px flex-1 bg-[var(--accent,#3E6B48)]/40"></span>
          </div>
          <%= if @editing_post_id == post.id do %>
            <form phx-submit="save_edit" class="rounded-box border border-base-300 p-4">
              <input type="hidden" name="post_id" value={post.id} />
              <textarea name="body_markdown" rows="4" class="textarea w-full" required>{post.body_markdown}</textarea>
              <div class="flex gap-2 pt-2">
                <.button variant="primary" class="btn-sm">{gettext("Save")}</.button>
                <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">
                  {gettext("Cancel")}
                </button>
              </div>
            </form>
          <% else %>
            <.post_card
              post={post}
              current_user={current_user(assigns)}
              permissions={post_permissions(post, @group, @relationship, current_user(assigns))}
              new_since_last_visit={false}
              guest_comment_allowed={@guest_comment_allowed?}
            />
          <% end %>
        </div>

        <.empty_state
          :if={@posts == []}
          icon="hero-chat-bubble-left-right"
          headline={gettext("No posts yet")}
          description={
            if Group.archived?(@group),
              do: gettext("This group is archived and read-only."),
              else: gettext("Be the first to write something.")
          }
        />
      </section>

      <%!-- Acknowledgment status modal --%>
      <dialog
        :if={@acknowledgment_status}
        open
        class="modal modal-open"
        phx-click="close_acknowledgment_status"
      >
        <div class="modal-box" phx-click={Phoenix.LiveView.JS.exec("phx-noop")}>
          <h3 class="pb-2 font-semibold">{gettext("Acknowledgments")}</h3>
          <div class="grid grid-cols-2 gap-4 text-sm">
            <div>
              <p class="pb-1 font-medium text-success">{gettext("Acknowledged")}</p>
              <p :for={user <- @acknowledgment_status.status.acknowledged} class="truncate">
                {user.display_name}
              </p>
            </div>
            <div>
              <p class="pb-1 font-medium text-base-content/60">{gettext("Not yet")}</p>
              <p :for={user <- @acknowledgment_status.status.pending} class="truncate">
                {user.display_name}
              </p>
            </div>
          </div>
          <div class="modal-action">
            <button class="btn btn-sm" phx-click="close_acknowledgment_status">
              {gettext("Close")}
            </button>
          </div>
        </div>
      </dialog>

      <section :if={@members != []} class="pt-6">
        <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Members")}
        </h2>
        <ul class="space-y-1">
          <li :for={membership <- @members} class="flex items-center gap-3 rounded-field px-2 py-1.5">
            <.user_avatar user={membership.user} size_class="size-8" text_class="text-xs" />
            <span class="truncate">{membership.user.display_name}</span>
            <span :if={membership.role != :member} class="badge badge-ghost badge-sm">
              {role_label(membership.role)}
            </span>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"group_slug" => group_slug}, _session, socket) do
    current_user = current_user(socket.assigns)
    community = socket.assigns.active_community

    case Groups.fetch_viewable_group(current_user, community, group_slug) do
      {:ok, group} ->
        if connected?(socket), do: Feed.subscribe(group)
        previous_visit = Feed.record_visit(current_user, group)

        {:ok,
         socket
         |> assign(:group, group)
         |> assign(:previous_visit, previous_visit)
         |> assign(:composer_form, to_form(%{}, as: "post"))
         |> assign(:show_poll_builder, false)
         |> assign(:poll_option_count, 2)
         |> assign(:editing_post_id, nil)
         |> assign(:acknowledgment_status, nil)
         |> allow_upload(:attachments,
           accept: :any,
           max_entries: 8,
           max_file_size: Files.upload_limit_bytes()
         )
         |> refresh(current_user)}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Group not found."))
         |> push_navigate(to: ~p"/c/#{community.slug}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({Kammer.Feed, _event}, socket) do
    {:noreply, refresh(socket, current_user(socket.assigns))}
  end

  # Guest-comment confirmation emails are delivered from this process;
  # Swoosh's test adapter echoes every delivery back as {:email, _}.
  def handle_info({:email, _email}, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event(event, params, socket) when event in @feed_events do
    FeedEventHandlers.handle(event, params, socket, fn socket ->
      refresh(socket, current_user(socket.assigns))
    end)
  end

  # Round-trip ALL composer params: LiveView resets unfocused inputs to
  # server-rendered values on every patch, so any field not driven by
  # @composer_form (poll options, checkboxes) would silently lose user
  # input the moment another field triggers a change event.
  def handle_event("validate_post", %{"post" => post_params}, socket) do
    {:noreply, assign(socket, :composer_form, to_form(post_params, as: "post"))}
  end

  def handle_event("guest_comment", %{"post_id" => post_id, "guest" => guest_params}, socket) do
    group = socket.assigns.group

    with %Kammer.Feed.Post{} = post <- Kammer.Repo.get(Kammer.Feed.Post, post_id),
         :ok <-
           Feed.request_guest_comment(post, group, guest_params,
             client_ip: nil,
             confirm_url_fun: fn token -> url(~p"/guest/comment/confirm/#{token}") end
           ) do
      {:noreply,
       put_flash(
         socket,
         :info,
         gettext("Check your email — follow the link there to submit your comment.")
       )}
    else
      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many attempts — please try again later."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(socket, :error, gettext("Please fill in a valid name, email, and comment."))}

      _error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("toggle_poll_builder", _params, socket) do
    {:noreply, assign(socket, :show_poll_builder, !socket.assigns.show_poll_builder)}
  end

  def handle_event("add_poll_option", _params, socket) do
    {:noreply, assign(socket, :poll_option_count, socket.assigns.poll_option_count + 1)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  def handle_event("create_post", %{"post" => post_params}, socket) do
    current_user = current_user(socket.assigns)
    group = socket.assigns.group

    stored_file_ids = store_attachments(socket, post_params["transient"] == "true")

    attrs =
      post_params
      |> Map.put("stored_file_ids", stored_file_ids)
      |> put_scheduled_publish_time(current_user)
      |> put_poll_attrs(current_user)

    case Feed.create_post(current_user, group, attrs) do
      {:ok, _post} ->
        {:noreply,
         socket
         |> assign(:composer_form, to_form(%{}, as: "post"))
         |> assign(:show_poll_builder, false)
         |> assign(:poll_option_count, 2)
         |> refresh(current_user)}

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, gettext("@everyone was used too recently in this group."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        message = changeset_error_message(changeset)
        {:noreply, put_flash(socket, :error, message)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("start_edit", %{"id" => post_id}, socket) do
    {:noreply, assign(socket, :editing_post_id, post_id)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing_post_id, nil)}
  end

  def handle_event("save_edit", %{"post_id" => post_id, "body_markdown" => body}, socket) do
    current_user = current_user(socket.assigns)

    with %Kammer.Feed.Post{} = post <- Kammer.Repo.get(Kammer.Feed.Post, post_id),
         {:ok, _post} <- Feed.edit_post(current_user, post, %{"body_markdown" => body}) do
      {:noreply, socket |> assign(:editing_post_id, nil) |> refresh(current_user)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("close_acknowledgment_status", _params, socket) do
    {:noreply, assign(socket, :acknowledgment_status, nil)}
  end

  def handle_event("join", _params, socket) do
    current_user = current_user(socket.assigns)

    case Groups.join_group(current_user, socket.assigns.group) do
      {:ok, _membership} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Welcome to the group!")) |> refresh(current_user)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("request_to_join", _params, socket) do
    current_user = current_user(socket.assigns)

    case Groups.request_to_join(current_user, socket.assigns.group) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Request sent — an admin will review it."))
         |> refresh(current_user)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("toggle_show_in_home", _params, socket) do
    membership = socket.assigns.membership
    current_user = current_user(socket.assigns)

    case Groups.set_show_in_home(current_user, socket.assigns.group, !membership.show_in_home) do
      {:ok, updated} ->
        {:noreply, assign(socket, :membership, updated)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("set_notification_level", %{"level" => level}, socket)
      when level in ~w(everything highlights mentions_only muted) do
    current_user = current_user(socket.assigns)

    {:ok, _preference} =
      Kammer.Notifications.set_level(
        current_user,
        socket.assigns.group,
        String.to_existing_atom(level)
      )

    {:noreply, refresh(socket, current_user)}
  end

  def handle_event("leave", _params, socket) do
    current_user = current_user(socket.assigns)

    case Groups.leave_group(current_user, socket.assigns.group) do
      {:ok, _membership} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("You left the group."))
         |> push_navigate(to: ~p"/c/#{socket.assigns.active_community.slug}/groups")}

      {:error, :owner_cannot_leave} ->
        {:noreply,
         put_flash(socket, :error, gettext("Owners must transfer ownership before leaving."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  ## Internals

  defp store_attachments(socket, transient?) do
    current_user = current_user(socket.assigns)
    group = socket.assigns.group

    consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
      case Files.create_from_upload(
             current_user,
             group,
             path,
             %{filename: entry.client_name, content_type: entry.client_type},
             transient: transient?
           ) do
        {:ok, stored_file} -> {:ok, stored_file.id}
        {:error, _reason} -> {:postpone, nil}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp put_scheduled_publish_time(attrs, current_user) do
    case parse_local_datetime(attrs["scheduled_for"], current_user) do
      nil -> attrs
      datetime -> Map.put(attrs, "published_at", datetime)
    end
  end

  # Reads a nested poll param ("post[poll][...]") back out of the
  # composer form for controlled rendering.
  defp poll_param(form, path), do: get_in(form.params, ["poll" | path])

  defp put_poll_attrs(attrs, current_user) do
    case attrs["poll"] do
      %{"options" => _options} = poll_attrs ->
        options_present? =
          poll_attrs["options"]
          |> Map.values()
          |> Enum.any?(fn option -> String.trim(option["text"] || "") != "" end)

        if options_present? do
          options =
            poll_attrs["options"]
            |> Enum.sort_by(fn {index, _option} -> index end)
            |> Enum.map(fn {index, option} -> {index, Map.put(option, "position", index)} end)
            |> Enum.reject(fn {_index, option} -> String.trim(option["text"] || "") == "" end)
            |> Map.new()

          poll_attrs =
            poll_attrs
            |> Map.put("options", options)
            |> Map.put("closes_at", parse_local_datetime(poll_attrs["closes_for"], current_user))

          Map.put(attrs, "poll", poll_attrs)
        else
          Map.delete(attrs, "poll")
        end

      _no_poll ->
        Map.delete(attrs, "poll")
    end
  end

  # datetime-local inputs are in the user's timezone (SPEC §1: stored
  # UTC, rendered per user).
  defp parse_local_datetime(nil, _user), do: nil
  defp parse_local_datetime("", _user), do: nil

  defp parse_local_datetime(value, user) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(value <> ":00"),
         {:ok, local} <- DateTime.from_naive(naive, user.timezone) do
      DateTime.shift_zone!(local, "Etc/UTC")
    else
      _error -> nil
    end
  end

  defp refresh(socket, current_user) do
    group = socket.assigns.group
    relationship = Authorization.relationship(current_user, group)

    members =
      case Groups.list_members(current_user, group) do
        {:ok, members} -> members
        {:error, :unauthorized} -> []
      end

    posts = Feed.list_group_feed(current_user, group)

    permissions = %{
      join: Authorization.can?(current_user, :join_group, group, relationship),
      request_to_join:
        Authorization.can?(current_user, :request_to_join_group, group, relationship),
      manage: Authorization.can?(current_user, :manage_group, group, relationship),
      post: Authorization.can?(current_user, :post_in_group, group, relationship),
      post_as_group: Authorization.can?(current_user, :post_as_group, group, relationship)
    }

    notification_level =
      if current_user do
        Atom.to_string(Kammer.Notifications.effective_level(current_user, group))
      end

    socket
    |> assign(:relationship, relationship)
    |> assign(
      :guest_comment_allowed?,
      is_nil(current_user) and Authorization.can_guest_comment?(group)
    )
    |> assign(:notification_level, notification_level)
    |> assign(:membership, Groups.get_membership(group, current_user))
    |> assign(:pending_request?, Groups.pending_join_request?(current_user, group))
    |> assign(:members, members)
    |> assign(:permissions, permissions)
    |> assign(:posts, posts)
    |> assign(:first_new_post_id, first_new_post_id(posts, socket.assigns.previous_visit))
  end

  defp first_new_post_id(_posts, nil), do: nil

  defp first_new_post_id(posts, previous_visit) do
    posts
    |> Enum.filter(fn post ->
      is_nil(post.pinned_at) and DateTime.compare(post.published_at, previous_visit) == :gt
    end)
    |> List.last()
    |> case do
      nil -> nil
      post -> post.id
    end
  end

  defp post_permissions(post, group, relationship, current_user) do
    %{
      edit: Authorization.can_edit_post?(current_user, post, group, relationship),
      soft_delete: Authorization.can_soft_delete_post?(current_user, post, group, relationship),
      hard_delete: Authorization.can_hard_delete_post?(current_user, post, group, relationship),
      pin: Authorization.can_pin_post?(current_user, post, group, relationship),
      lock_comments:
        Authorization.can_lock_post_comments?(current_user, post, group, relationship),
      view_acknowledgments:
        current_user != nil and
          Authorization.can_view_acknowledgments?(current_user, post, group, relationship),
      approve: Authorization.can?(current_user, :moderate_group, group, relationship),
      comment: Authorization.can?(current_user, :comment_in_group, group, relationship),
      react: Authorization.can_react?(current_user, group, relationship)
    }
  end

  defp upload_error_message(:too_large), do: gettext("File is too large.")
  defp upload_error_message(:too_many_files), do: gettext("Too many files.")
  defp upload_error_message(_other), do: gettext("Upload failed.")

  defp changeset_error_message(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _opts}} -> "#{field} #{message}" end)
    |> Enum.join(", ")
    |> case do
      "" -> gettext("Could not create the post.")
      message -> message
    end
  end

  defp current_user(%{current_scope: %{user: user}}), do: user
  defp current_user(_assigns), do: nil

  defp member_of_community?(%{community_role: role}), do: role != nil
  defp member_of_community?(_relationship), do: false

  defp notification_level_options do
    [
      {"everything", gettext("Everything")},
      {"highlights", gettext("Highlights")},
      {"mentions_only", gettext("Mentions only")},
      {"muted", gettext("Muted")}
    ]
  end

  defp role_label(:owner), do: gettext("Owner")
  defp role_label(:admin), do: gettext("Admin")
  defp role_label(:member), do: gettext("Member")
end
