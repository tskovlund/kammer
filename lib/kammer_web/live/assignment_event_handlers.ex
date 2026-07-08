defmodule KammerWeb.AssignmentEventHandlers do
  @moduledoc """
  Shared LiveView event handling for assignment claim/unclaim/complete/
  reopen, so the group assignment list and single-assignment page behave
  identically. The host LiveView resolves the target `Assignment` (or,
  for unclaim, looks up nothing — an id is enough) and supplies a
  `reload` function.
  """

  use Gettext, backend: KammerWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kammer.Assignments
  alias Kammer.Assignments.Assignment
  alias Kammer.Assignments.AssignmentClaim
  alias Kammer.Repo

  @type reload_fun() :: (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())

  @spec handle_claim(Phoenix.LiveView.Socket.t(), Assignment.t() | nil, reload_fun()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_claim(socket, assignment, reload) do
    with %Assignment{} <- assignment,
         {:ok, _claim} <- Assignments.claim(current_user(socket), assignment) do
      {:noreply, reload.(socket)}
    else
      _error -> {:noreply, refuse(socket)}
    end
  end

  @spec handle_unclaim(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), reload_fun()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_unclaim(socket, assignment_id, reload) do
    current_user = current_user(socket)

    claim =
      Repo.get_by(AssignmentClaim, assignment_id: assignment_id, user_id: current_user.id)

    with %AssignmentClaim{} <- claim,
         {:ok, _claim} <- Assignments.unclaim(current_user, claim) do
      {:noreply, reload.(socket)}
    else
      _error -> {:noreply, refuse(socket)}
    end
  end

  @spec handle_complete(Phoenix.LiveView.Socket.t(), Assignment.t() | nil, reload_fun()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_complete(socket, assignment, reload) do
    with %Assignment{} <- assignment,
         {:ok, _assignment} <- Assignments.complete(current_user(socket), assignment) do
      {:noreply, reload.(socket)}
    else
      _error -> {:noreply, refuse(socket)}
    end
  end

  @spec handle_reopen(Phoenix.LiveView.Socket.t(), Assignment.t() | nil, reload_fun()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_reopen(socket, assignment, reload) do
    with %Assignment{} <- assignment,
         {:ok, _assignment} <- Assignments.reopen(current_user(socket), assignment) do
      {:noreply, reload.(socket)}
    else
      _error -> {:noreply, refuse(socket)}
    end
  end

  defp current_user(socket), do: socket.assigns.current_scope.user

  defp refuse(socket) do
    put_flash(socket, :error, gettext("You are not allowed to do that."))
  end
end
