defmodule KammerWeb.UserLive.Devices do
  @moduledoc """
  Devices page (SPEC §2): lists the account's long-lived sessions with
  device information and lets the user revoke any of them individually.
  """

  use KammerWeb, :live_view

  on_mount {KammerWeb.UserAuth, :require_sudo_mode}

  alias Kammer.Accounts

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl space-y-6">
        <.header>
          {gettext("Devices")}
          <:subtitle>
            {gettext("Sessions signed in to your account. Revoke any you don't recognize.")}
          </:subtitle>
        </.header>

        <ul id="user-sessions" class="space-y-3">
          <li
            :for={session <- @sessions}
            class="flex items-center justify-between gap-4 rounded-box border border-base-300 p-4"
          >
            <div class="min-w-0">
              <p class="truncate font-medium">
                {device_description(session.user_agent)}
                <span :if={session.current?} class="badge badge-primary badge-sm ml-2">
                  {gettext("This device")}
                </span>
              </p>
              <p class="text-sm opacity-70">
                {gettext("Signed in %{timestamp}", timestamp: format_datetime(session.inserted_at))}
              </p>
            </div>
            <.button
              :if={!session.current?}
              phx-click="revoke"
              phx-value-id={session.id}
              data-confirm={gettext("Sign this device out?")}
              class="btn btn-outline btn-sm"
            >
              {gettext("Revoke")}
            </.button>
          </li>
        </ul>

        <p class="text-sm opacity-70">
          {gettext("To sign out this device, use the sign-out button in the menu.")}
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    {:ok, load_sessions(socket, session["user_token"])}
  end

  @impl Phoenix.LiveView
  def handle_event("revoke", %{"id" => token_id}, socket) do
    user = socket.assigns.current_scope.user
    :ok = Accounts.revoke_user_session(user, token_id)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Device signed out."))
     |> load_sessions(socket.assigns.current_session_token)}
  end

  defp load_sessions(socket, current_session_token) do
    sessions =
      socket.assigns.current_scope.user
      |> Accounts.list_user_sessions()
      |> Enum.map(fn user_token ->
        %{
          id: user_token.id,
          user_agent: user_token.user_agent,
          inserted_at: user_token.inserted_at,
          current?: Plug.Crypto.secure_compare(user_token.token, current_session_token || <<>>)
        }
      end)

    socket
    |> assign(:current_session_token, current_session_token)
    |> assign(:sessions, sessions)
  end

  defp device_description(nil), do: gettext("Unknown device")

  defp device_description(user_agent) do
    browser =
      cond do
        String.contains?(user_agent, "Firefox/") -> "Firefox"
        String.contains?(user_agent, "Edg/") -> "Edge"
        String.contains?(user_agent, "Chrome/") -> "Chrome"
        String.contains?(user_agent, "Safari/") -> "Safari"
        true -> gettext("Browser")
      end

    platform =
      cond do
        String.contains?(user_agent, "iPhone") -> "iPhone"
        String.contains?(user_agent, "iPad") -> "iPad"
        String.contains?(user_agent, "Android") -> "Android"
        String.contains?(user_agent, "Mac OS X") -> "macOS"
        String.contains?(user_agent, "Windows") -> "Windows"
        String.contains?(user_agent, "Linux") -> "Linux"
        true -> nil
      end

    if platform, do: "#{browser} · #{platform}", else: browser
  end

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end
end
