defmodule KammerWeb.UserLive.Confirmation do
  @moduledoc """
  Magic-link landing page: confirms the account on first use and signs the
  user in. The explicit button press prevents email-scanner bots from
  consuming the single-use link.
  """

  use KammerWeb, :live_view

  alias Kammer.Accounts

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>{gettext("Welcome %{email}", email: @user.email)}</.header>
        </div>

        <.form
          :if={!@user.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with={gettext("Confirming...")}
            class="btn btn-primary w-full"
          >
            {gettext("Confirm and stay signed in")}
          </.button>
          <.button
            phx-disable-with={gettext("Confirming...")}
            class="btn btn-primary btn-soft w-full mt-2"
          >
            {gettext("Confirm and sign in only this time")}
          </.button>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <.button phx-disable-with={gettext("Signing in...")} class="btn btn-primary w-full">
              {gettext("Sign in")}
            </.button>
          <% else %>
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with={gettext("Signing in...")}
              class="btn btn-primary w-full"
            >
              {gettext("Keep me signed in on this device")}
            </.button>
            <.button
              phx-disable-with={gettext("Signing in...")}
              class="btn btn-primary btn-soft w-full mt-2"
            >
              {gettext("Sign me in only this time")}
            </.button>
          <% end %>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Magic link is invalid or it has expired."))
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
