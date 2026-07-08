defmodule KammerWeb.BanEventHandlers do
  @moduledoc """
  Shared LiveView event handling for lifting a ban, so community and
  instance moderation behave identically. The host LiveView supplies the
  looked-up ban, the scope-specific unban function, and a `reload`
  function.
  """

  use Gettext, backend: KammerWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kammer.Accounts.User

  @type reload_fun() :: (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())
  @type unban_fun(ban) :: (User.t(), ban -> {:ok, ban} | {:error, term()})

  @spec handle_unban(
          Phoenix.LiveView.Socket.t(),
          struct() | nil,
          unban_fun(struct()),
          reload_fun()
        ) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_unban(socket, ban, unban_fun, reload) do
    with ban when not is_nil(ban) <- ban,
         {:ok, _ban} <- unban_fun.(current_user(socket), ban) do
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
