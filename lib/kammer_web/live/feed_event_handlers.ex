defmodule KammerWeb.FeedEventHandlers do
  @moduledoc """
  Shared LiveView event handling for feed interactions (reactions,
  comments, votes, acknowledgments, moderation) so the group feed and the
  aggregated home feed behave identically. The host LiveView supplies a
  `reload` function; all authorization happens in `Kammer.Feed` /
  `Kammer.Authorization`.
  """

  use Gettext, backend: KammerWeb.Gettext

  import Ecto.Query, only: [from: 2]
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kammer.Feed
  alias Kammer.Feed.Comment
  alias Kammer.Feed.Post
  alias Kammer.Repo

  @type reload_fun() :: (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())

  @doc """
  Handles a feed interaction event. Returns `{:noreply, socket}`.
  """
  @spec handle(String.t(), map(), Phoenix.LiveView.Socket.t(), reload_fun()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle(event, params, socket, reload)

  def handle(
        "toggle_reaction",
        %{"type" => type, "id" => subject_id, "emoji" => emoji},
        socket,
        reload
      ) do
    subject =
      case type do
        "post" -> Repo.get(Post, subject_id)
        "comment" -> Repo.get(Comment, subject_id)
      end

    if subject do
      case Feed.toggle_reaction(current_user(socket), subject, emoji) do
        {:ok, _change} -> {:noreply, reload.(socket)}
        {:error, _reason} -> {:noreply, refuse(socket)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle("create_comment", params, socket, reload) do
    with %Post{} = post <- Repo.get(Post, params["post_id"]),
         {:ok, _comment} <-
           Feed.create_comment(current_user(socket), post, %{
             "body_markdown" => params["body_markdown"],
             "parent_comment_id" => params["parent_comment_id"]
           }) do
      {:noreply, reload.(socket)}
    else
      {:error, :comments_locked} ->
        {:noreply, put_flash(socket, :error, gettext("Comments are locked on this post."))}

      _error ->
        {:noreply, refuse(socket)}
    end
  end

  def handle("delete_comment", %{"id" => comment_id}, socket, reload) do
    with %Comment{} = comment <- Repo.get(Comment, comment_id),
         {:ok, _deleted} <- Feed.delete_comment(current_user(socket), comment) do
      {:noreply, reload.(socket)}
    else
      _error -> {:noreply, refuse(socket)}
    end
  end

  def handle("vote_poll", %{"poll-id" => poll_id, "option-id" => option_id}, socket, reload) do
    with %Feed.Poll{} = poll <- Repo.get(Feed.Poll, poll_id) do
      option_ids = toggle_option(current_user(socket), poll, option_id)

      case Feed.vote(current_user(socket), poll, option_ids) do
        :ok ->
          {:noreply, reload.(socket)}

        {:error, :poll_closed} ->
          {:noreply, put_flash(socket, :error, gettext("This poll is closed."))}

        {:error, _reason} ->
          {:noreply, refuse(socket)}
      end
    else
      _missing -> {:noreply, socket}
    end
  end

  def handle("acknowledge", %{"id" => post_id}, socket, reload) do
    with %Post{} = post <- Repo.get(Post, post_id),
         {:ok, _acknowledgment} <- Feed.acknowledge_post(current_user(socket), post) do
      {:noreply, reload.(socket)}
    else
      _error -> {:noreply, refuse(socket)}
    end
  end

  def handle("show_acknowledgment_status", %{"id" => post_id}, socket, _reload) do
    with %Post{} = post <- Repo.get(Post, post_id),
         {:ok, status} <- Feed.acknowledgment_status(current_user(socket), post) do
      {:noreply, assign(socket, :acknowledgment_status, %{post_id: post_id, status: status})}
    else
      _error -> {:noreply, refuse(socket)}
    end
  end

  def handle("toggle_pin", %{"id" => post_id}, socket, reload) do
    with %Post{} = post <- Repo.get(Post, post_id),
         {:ok, _post} <- Feed.set_pinned(current_user(socket), post, is_nil(post.pinned_at)) do
      {:noreply, reload.(socket)}
    else
      _error -> {:noreply, refuse(socket)}
    end
  end

  def handle("toggle_comment_lock", %{"id" => post_id}, socket, reload) do
    with %Post{} = post <- Repo.get(Post, post_id),
         {:ok, _post} <-
           Feed.set_comments_locked(current_user(socket), post, is_nil(post.comment_locked_at)) do
      {:noreply, reload.(socket)}
    else
      _error -> {:noreply, refuse(socket)}
    end
  end

  def handle("approve_post", %{"id" => post_id}, socket, reload) do
    with %Post{} = post <- Repo.get(Post, post_id),
         {:ok, _post} <- Feed.approve_post(current_user(socket), post) do
      {:noreply, reload.(socket)}
    else
      _error -> {:noreply, refuse(socket)}
    end
  end

  def handle("soft_delete_post", %{"id" => post_id}, socket, reload) do
    with %Post{} = post <- Repo.get(Post, post_id),
         {:ok, _post} <- Feed.soft_delete_post(current_user(socket), post) do
      {:noreply, reload.(socket)}
    else
      _error -> {:noreply, refuse(socket)}
    end
  end

  def handle("hard_delete_post", %{"id" => post_id}, socket, reload) do
    with %Post{} = post <- Repo.get(Post, post_id),
         {:ok, _post} <- Feed.hard_delete_post(current_user(socket), post) do
      {:noreply, reload.(socket)}
    else
      _error -> {:noreply, refuse(socket)}
    end
  end

  # Single-choice: voting for an option selects it (replacing the old
  # vote); clicking the already-selected option clears the vote.
  # Multiple-choice: toggles the option within the current selection.
  defp toggle_option(user, poll, option_id) do
    current_option_ids =
      Repo.all(
        from(vote in Feed.PollVote,
          where: vote.poll_id == ^poll.id and vote.user_id == ^user.id,
          select: vote.option_id
        )
      )

    cond do
      option_id in current_option_ids and poll.multiple_choice ->
        current_option_ids -- [option_id]

      option_id in current_option_ids ->
        []

      poll.multiple_choice ->
        [option_id | current_option_ids]

      true ->
        [option_id]
    end
  end

  defp current_user(socket) do
    case socket.assigns[:current_scope] do
      %{user: user} -> user
      _no_scope -> nil
    end
  end

  defp refuse(socket) do
    put_flash(socket, :error, gettext("You are not allowed to do that."))
  end
end
