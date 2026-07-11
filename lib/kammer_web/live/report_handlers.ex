defmodule KammerWeb.ReportHandlers do
  @moduledoc """
  Shared LiveView event handling for the "report to moderators" flow
  (SPEC §11), paired with `KammerWeb.KammerComponents.report_modal/1`
  so the group feed, event pages, and assignment pages all report
  posts/comments identically. The host LiveView owns the `reporting`
  assign (`nil` or `%{type:, id:}`, initialized in `mount/3`); nothing
  here ever needs to reload the host page's data — dismissing the
  modal is the only state change either outcome causes.
  """

  use Gettext, backend: KammerWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kammer.Feed
  alias Kammer.Feed.Comment
  alias Kammer.Feed.Post
  alias Kammer.Moderation

  @doc """
  Handles a report-flow event. Returns `{:noreply, socket}`.
  """
  @spec handle(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle(event, params, socket)

  def handle("start_report", %{"type" => type, "id" => subject_id}, socket)
      when type in ["post", "comment"] do
    {:noreply, assign(socket, :reporting, %{type: type, id: subject_id})}
  end

  def handle("cancel_report", _params, socket) do
    {:noreply, assign(socket, :reporting, nil)}
  end

  def handle("submit_report", %{"reason" => reason}, socket) do
    current_user = current_user(socket)
    reporting = socket.assigns.reporting

    result =
      case reporting do
        %{type: "post", id: post_id} ->
          with %Post{} = post <- Feed.get_post(post_id) do
            Moderation.report_post(current_user, post, reason)
          end

        %{type: "comment", id: comment_id} ->
          with %Comment{} = comment <- Feed.get_comment(comment_id) do
            Moderation.report_comment(current_user, comment, reason)
          end

        _no_subject ->
          {:error, :unauthorized}
      end

    case result do
      {:ok, _report} ->
        {:noreply,
         socket
         |> assign(:reporting, nil)
         |> put_flash(:info, gettext("Thanks — the moderators will take a look."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        if Moderation.duplicate_report?(changeset) do
          {:noreply,
           socket
           |> assign(:reporting, nil)
           |> put_flash(:info, gettext("You already reported this — the moderators have it."))}
        else
          {:noreply,
           socket
           |> assign(:reporting, nil)
           |> put_flash(:error, gettext("The report could not be sent — check the reason text."))}
        end

      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> assign(:reporting, nil)
         |> put_flash(:error, gettext("Too many attempts. Please try again later."))}

      _error ->
        {:noreply,
         socket
         |> assign(:reporting, nil)
         |> put_flash(:error, gettext("You are not allowed to do that."))}
    end
  end

  defp current_user(socket) do
    case socket.assigns[:current_scope] do
      %{user: user} -> user
      _no_scope -> nil
    end
  end
end
