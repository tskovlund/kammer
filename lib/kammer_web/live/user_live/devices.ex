defmodule KammerWeb.UserLive.Devices do
  @moduledoc """
  Devices page (SPEC §2): lists the account's revocable credentials —
  browser sessions and long-lived API device tokens alike (issue
  #174) — with device information, and lets the user revoke any of
  them individually.
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
                {session.description}
                <span :if={session.api_device?} class="badge badge-ghost badge-sm ml-2">
                  {gettext("App")}
                </span>
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

        <.header>
          {gettext("Passkeys")}
          <:subtitle>
            {gettext("Sign in with your device's fingerprint, face, or screen lock — no email hop.")}
          </:subtitle>
          <:actions>
            <button
              :if={@passkey_registration_challenge}
              type="button"
              id="passkey-register-button"
              phx-hook=".PasskeyRegister"
              data-challenge={
                Base.url_encode64(@passkey_registration_challenge.bytes, padding: false)
              }
              data-rp-id={@passkey_registration_challenge.rp_id}
              data-user-id={Base.url_encode64(@current_scope.user.id, padding: false)}
              data-user-name={@current_scope.user.email}
              data-user-display-name={@current_scope.user.display_name}
              data-exclude-credentials={
                Jason.encode!(
                  Enum.map(@passkeys, &Base.url_encode64(&1.credential_id, padding: false))
                )
              }
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-plus" class="size-4" /> {gettext("Add a passkey")}
            </button>

            <script :type={Phoenix.LiveView.ColocatedHook} name=".PasskeyRegister">
              import { b64urlToBytes, bytesToB64url } from "@/js/webauthn"

              export default {
                mounted() {
                  this.el.addEventListener("click", () => this.register())
                },
                async register() {
                  if (!window.PublicKeyCredential) {
                    this.pushEvent("passkey_unsupported", {})
                    return
                  }

                  try {
                    const excludeCredentials = JSON.parse(
                      this.el.dataset.excludeCredentials,
                    ).map((id) => ({ type: "public-key", id: b64urlToBytes(id) }))

                    const credential = await navigator.credentials.create({
                      publicKey: {
                        challenge: b64urlToBytes(this.el.dataset.challenge),
                        rp: { id: this.el.dataset.rpId, name: "Kammer" },
                        user: {
                          id: b64urlToBytes(this.el.dataset.userId),
                          name: this.el.dataset.userName,
                          displayName: this.el.dataset.userDisplayName,
                        },
                        pubKeyCredParams: [
                          { type: "public-key", alg: -7 },
                          { type: "public-key", alg: -257 },
                        ],
                        authenticatorSelection: {
                          residentKey: "required",
                          userVerification: "preferred",
                        },
                        excludeCredentials,
                        timeout: 60000,
                      },
                    })

                    this.pushEvent("passkey_attestation", {
                      attestation_object: bytesToB64url(credential.response.attestationObject),
                      client_data_json: bytesToB64url(credential.response.clientDataJSON),
                    })
                  } catch (_error) {
                    // The user cancelled, or the authenticator refused.
                  }
                },
              }
            </script>
          </:actions>
        </.header>

        <ul id="user-passkeys" class="space-y-3">
          <li
            :for={passkey <- @passkeys}
            class="flex items-center justify-between gap-4 rounded-box border border-base-300 p-4"
          >
            <div class="min-w-0">
              <p class="truncate font-medium">{passkey.nickname || gettext("Passkey")}</p>
              <p class="text-sm opacity-70">
                {gettext("Added %{timestamp}", timestamp: format_datetime(passkey.inserted_at))}
                <span :if={passkey.last_used_at}>
                  · {gettext("last used %{timestamp}",
                    timestamp: format_datetime(passkey.last_used_at)
                  )}
                </span>
              </p>
            </div>
            <.button
              phx-click="delete_passkey"
              phx-value-id={passkey.id}
              data-confirm={gettext("Remove this passkey?")}
              class="btn btn-outline btn-sm"
            >
              {gettext("Remove")}
            </.button>
          </li>
        </ul>

        <p :if={@passkeys == []} class="text-sm opacity-70">
          {gettext("No passkeys yet.")}
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    socket =
      socket
      |> load_sessions(session["user_token"])
      |> load_passkeys()

    socket =
      if connected?(socket) do
        assign_passkey_registration_challenge(socket)
      else
        assign(socket, :passkey_registration_challenge, nil)
      end

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("revoke", %{"id" => token_id}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.revoke_user_device(user, token_id) do
      {:ok, %Kammer.Accounts.UserToken{context: "api-device"}} ->
        # Sever live sockets riding the revoked token (issue #174) —
        # the same broadcast the API revoke endpoint sends; sibling
        # devices reconnect with their still-valid tokens.
        KammerWeb.Endpoint.broadcast("api_user_socket:#{user.id}", "disconnect", %{})
        :ok

      _revoked_or_gone ->
        :ok
    end

    {:noreply,
     socket
     |> put_flash(:info, gettext("Device signed out."))
     |> load_sessions(socket.assigns.current_session_token)}
  end

  def handle_event("passkey_attestation", params, socket) do
    with {:ok, attestation_object} <- decode_b64url(params["attestation_object"]),
         {:ok, client_data_json} <- decode_b64url(params["client_data_json"]),
         {:ok, _passkey} <-
           Accounts.register_passkey(
             socket.assigns.current_scope.user,
             attestation_object,
             client_data_json,
             socket.assigns.passkey_registration_challenge
           ) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Passkey added."))
       |> load_passkeys()
       |> assign_passkey_registration_challenge()}
    else
      _error ->
        {:noreply,
         put_flash(socket, :error, gettext("Couldn't add that passkey. Please try again."))}
    end
  end

  def handle_event("delete_passkey", %{"id" => passkey_id}, socket) do
    :ok = Accounts.delete_passkey(socket.assigns.current_scope.user, passkey_id)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Passkey removed."))
     |> load_passkeys()}
  end

  def handle_event("passkey_unsupported", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("This browser doesn't support passkeys."))}
  end

  defp load_sessions(socket, current_session_token) do
    sessions =
      socket.assigns.current_scope.user
      |> Accounts.list_user_devices()
      |> Enum.map(fn user_token ->
        api_device? = user_token.context == "api-device"

        %{
          id: user_token.id,
          api_device?: api_device?,
          description: describe(user_token, api_device?),
          inserted_at: user_token.inserted_at,
          current?:
            not api_device? and
              Plug.Crypto.secure_compare(user_token.token, current_session_token || <<>>)
        }
      end)

    socket
    |> assign(:current_session_token, current_session_token)
    |> assign(:sessions, sessions)
  end

  # An API device's user_agent field carries the client-chosen device
  # name, not a browser UA string — show it verbatim (issue #174).
  defp describe(user_token, true), do: user_token.user_agent || gettext("API device")
  defp describe(user_token, false), do: device_description(user_token.user_agent)

  defp load_passkeys(socket) do
    assign(socket, :passkeys, Accounts.list_passkeys(socket.assigns.current_scope.user))
  end

  defp assign_passkey_registration_challenge(socket) do
    challenge =
      Accounts.new_passkey_registration_challenge(
        socket.assigns.current_scope.user,
        KammerWeb.Endpoint.url()
      )

    assign(socket, :passkey_registration_challenge, challenge)
  end

  defp decode_b64url(nil), do: :error
  defp decode_b64url(value), do: Base.url_decode64(value, padding: false)

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
