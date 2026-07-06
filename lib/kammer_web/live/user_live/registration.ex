defmodule KammerWeb.UserLive.Registration do
  @moduledoc """
  Registration page: email plus display name — the only required base
  profile field (SPEC §4). No password is ever set (SPEC §2).
  """

  use KammerWeb, :live_view

  alias Kammer.Accounts
  alias Kammer.Accounts.User

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            {gettext("Create an account")}
            <:subtitle>
              {gettext("Already registered?")}
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                {gettext("Sign in")}
              </.link>
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
          <.input
            field={@form[:display_name]}
            type="text"
            label={gettext("Display name")}
            autocomplete="name"
            required
            phx-mounted={JS.focus()}
          />

          <.input
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
          />

          <.button phx-disable-with={gettext("Creating account...")} class="btn btn-primary w-full">
            {gettext("Create an account")}
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: KammerWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_registration(%User{}, %{}, validate_unique: false)

    client_ip =
      case get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _other -> nil
      end

    {:ok, assign(assign_form(socket, changeset), :client_ip, client_ip),
     temporary_assigns: [form: nil]}
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        Accounts.deliver_login_instructions(
          user,
          &url(~p"/users/log-in/#{&1}"),
          ip: socket.assigns.client_ip
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("An email was sent to %{email}, please access it to confirm your account.",
             email: user.email
           )
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
