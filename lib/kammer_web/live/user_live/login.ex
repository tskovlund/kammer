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

    {:ok, assign(socket, form: form, client_ip: client_ip)}
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

  defp local_mail_adapter? do
    Application.get_env(:kammer, Kammer.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
