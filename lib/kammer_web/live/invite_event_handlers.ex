defmodule KammerWeb.InviteEventHandlers do
  @moduledoc """
  Shared LiveView event handling for invite-link creation/revocation, so
  group and community settings behave identically. The host LiveView
  supplies the scope-specific create function and a `reload` function.
  """

  use Gettext, backend: KammerWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kammer.Accounts.User
  alias Kammer.Invitations
  alias Kammer.Invitations.Invite

  @type reload_fun() :: (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())
  @type create_fun() :: (User.t() -> {:ok, Invite.t()} | {:error, term()})

  @doc """
  Creates an invite via `create_fun`, flashing success/failure and
  reloading via `reload` on success.
  """
  @spec handle_create_invite(Phoenix.LiveView.Socket.t(), create_fun(), reload_fun()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_create_invite(socket, create_fun, reload) do
    case create_fun.(current_user(socket)) do
      {:ok, _invite} ->
        {:noreply, socket |> put_flash(:info, gettext("Invite link created.")) |> reload.()}

      {:error, _reason} ->
        {:noreply, refuse(socket)}
    end
  end

  @doc """
  Revokes the invite with the given id from `socket.assigns.invites`, if
  present, flashing success/failure and reloading via `reload` on
  success.
  """
  @spec handle_revoke_invite(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), reload_fun()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_revoke_invite(socket, invite_id, reload) do
    invite = Enum.find(socket.assigns.invites, &(&1.id == invite_id))

    if invite do
      case Invitations.revoke_invite(current_user(socket), invite) do
        {:ok, _revoked} ->
          {:noreply, socket |> put_flash(:info, gettext("Invite revoked.")) |> reload.()}

        {:error, _reason} ->
          {:noreply, refuse(socket)}
      end
    else
      {:noreply, socket}
    end
  end

  defp current_user(socket), do: socket.assigns.current_scope.user

  defp refuse(socket) do
    put_flash(socket, :error, gettext("You are not allowed to do that."))
  end
end
