defmodule KammerWeb.UserLive.Login do
  @moduledoc """
  Sign-in page: requests a magic link (SPEC §2 — passwordless only).

  Rate limiting per email and per IP happens in the Accounts context; the
  page always answers neutrally so it cannot be used to probe which emails
  exist.
  """

  use KammerWeb, :live_view

  alias Kammer.Accounts

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>{gettext("Sign in")}</p>
            <:subtitle>
              <%= if @current_scope do %>
                {gettext("You need to reauthenticate to perform sensitive actions on your account.")}
              <% else %>
                {gettext("No password needed — we email you a sign-in link.")}
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <div :if={local_mail_adapter?()} class="alert alert-info">
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <p>{gettext("You are running the local mail adapter.")}</p>
            <p>
              {gettext("To see sent emails, visit")}
              <.link href="/dev/mailbox" class="underline">{gettext("the mailbox page")}</.link>.
            </p>
          </div>
        </div>

        <.form
          :let={form}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
        >
          <.input
            readonly={!!@current_scope}
            field={form[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button class="btn btn-primary w-full">
            {gettext("Email me a sign-in link")} <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <div :if={@passkey_challenge} class="space-y-2">
          <div class="divider text-xs uppercase text-base-content/40">{gettext("or")}</div>

          <button
            type="button"
            id="passkey-login-button"
            phx-hook=".PasskeyLogin"
            data-challenge={Base.url_encode64(@passkey_challenge.bytes, padding: false)}
            data-rp-id={@passkey_challenge.rp_id}
            class="btn btn-outline w-full"
          >
            <.icon name="hero-finger-print" class="size-5" />
            {gettext("Sign in with a passkey")}
          </button>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".PasskeyLogin">
            import { b64urlToBytes, bytesToB64url } from "@/js/webauthn"

            export default {
              mounted() {
                this.el.addEventListener("click", () => this.signIn())
              },
              async signIn() {
                if (!window.PublicKeyCredential) {
                  this.pushEvent("passkey_unsupported", {})
                  return
                }

                try {
                  const credential = await navigator.credentials.get({
                    publicKey: {
                      challenge: b64urlToBytes(this.el.dataset.challenge),
                      rpId: this.el.dataset.rpId,
                      userVerification: "preferred",
                      timeout: 60000,
                    },
                  })

                  this.pushEvent("passkey_assertion", {
                    credential_id: bytesToB64url(credential.rawId),
                    authenticator_data: bytesToB64url(credential.response.authenticatorData),
                    signature: bytesToB64url(credential.response.signature),
                    client_data_json: bytesToB64url(credential.response.clientDataJSON),
                  })
                } catch (_error) {
                  // The user cancelled, or the browser refused — the
                  // browser's own UI already explained why.
                }
              },
            }
          </script>
        </div>

        <.form
          :if={@passkey_challenge}
          for={@passkey_form}
          id="login_form_passkey"
          action={~p"/users/log-in/passkey"}
          phx-trigger-action={@passkey_trigger_submit}
        >
          <input type="hidden" name={@passkey_form[:token].name} value={@passkey_form[:token].value} />
        </.form>

        <p :if={!@current_scope} class="text-center text-sm">
          {gettext("New here?")}
          <.link navigate={~p"/users/register"} class="font-semibold text-brand hover:underline">
            {gettext("Create an account")}
          </.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    client_ip =
      case get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _other -> nil
      end

    socket =
      socket
      |> assign(form: form, client_ip: client_ip)
      |> assign(
        passkey_form: to_form(%{"token" => nil}, as: "user"),
        passkey_trigger_submit: false
      )

    socket =
      if connected?(socket),
        do: assign_passkey_challenge(socket),
        else: assign(socket, passkey_challenge: nil)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}"),
        ip: socket.assigns.client_ip
      )
    end

    info =
      gettext(
        "If your email is in our system, you will receive instructions for logging in shortly."
      )

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("passkey_assertion", params, socket) do
    with {:ok, credential_id} <- decode_b64url(params["credential_id"]),
         {:ok, auth_data} <- decode_b64url(params["authenticator_data"]),
         {:ok, sig} <- decode_b64url(params["signature"]),
         {:ok, client_data_json} <- decode_b64url(params["client_data_json"]),
         {:ok, user} <-
           Accounts.login_user_by_passkey(
             credential_id,
             auth_data,
             sig,
             client_data_json,
             socket.assigns.passkey_challenge
           ) do
      token = Accounts.build_passkey_login_exchange(user)

      {:noreply,
       socket
       |> assign(:passkey_form, to_form(%{"token" => token}, as: "user"))
       |> assign(:passkey_trigger_submit, true)}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That passkey didn't work. Please try again."))
         |> assign_passkey_challenge()}
    end
  end

  def handle_event("passkey_unsupported", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("This browser doesn't support passkeys."))}
  end

  defp assign_passkey_challenge(socket) do
    challenge = Accounts.new_passkey_authentication_challenge(KammerWeb.Endpoint.url())
    assign(socket, :passkey_challenge, challenge)
  end

  defp decode_b64url(nil), do: :error
  defp decode_b64url(value), do: Base.url_decode64(value, padding: false)

  defp local_mail_adapter? do
    Application.get_env(:kammer, Kammer.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
