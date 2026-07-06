defmodule KammerWeb.UserLive.Settings do
  @moduledoc """
  Account settings: email change (confirmed by magic link to the new
  address), display name, interface language, and timezone (SPEC §4).
  Sensitive actions require sudo mode (recent authentication).
  """

  use KammerWeb, :live_view

  on_mount {KammerWeb.UserAuth, :require_sudo_mode}

  alias Kammer.Accounts

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          {gettext("Account settings")}
          <:subtitle>
            {gettext("Manage your profile, email address, language, and devices")}
          </:subtitle>
        </.header>
      </div>

      <.form
        for={@settings_form}
        id="settings_form"
        phx-submit="update_settings"
        phx-change="validate_settings"
      >
        <.input
          field={@settings_form[:display_name]}
          type="text"
          label={gettext("Display name")}
          autocomplete="name"
          required
        />
        <.input
          field={@settings_form[:locale]}
          type="select"
          label={gettext("Language")}
          options={[{gettext("English"), "en"}, {gettext("Danish"), "da"}]}
        />
        <.input
          field={@settings_form[:timezone]}
          type="text"
          label={gettext("Timezone")}
          placeholder="Europe/Copenhagen"
        />
        <.button variant="primary" phx-disable-with={gettext("Saving...")}>
          {gettext("Save profile")}
        </.button>
      </.form>

      <div class="divider" />

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label={gettext("Email")}
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with={gettext("Changing...")}>
          {gettext("Change email")}
        </.button>
      </.form>

      <div class="divider" />

      <div class="flex flex-col items-center gap-2 text-center">
        <.link navigate={~p"/users/settings/devices"} class="link">
          {gettext("Manage devices and sessions")}
        </.link>
        <.link navigate={~p"/users/settings/servers"} class="link">
          {gettext("My other servers")}
        </.link>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, gettext("Email changed successfully."))

        {:error, _reason} ->
          put_flash(socket, :error, gettext("Email change link is invalid or it has expired."))
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    settings_changeset = Accounts.change_user_settings(user)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:settings_form, to_form(settings_changeset))

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = gettext("A link to confirm your email change has been sent to the new address.")
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_settings", params, socket) do
    %{"user" => user_params} = params

    settings_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_settings(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, settings_form: settings_form)}
  end

  def handle_event("update_settings", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    case Accounts.update_user_settings(user, user_params) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Profile updated."))
         |> assign(:settings_form, to_form(Accounts.change_user_settings(updated_user)))}

      {:error, changeset} ->
        {:noreply, assign(socket, :settings_form, to_form(changeset, action: :insert))}
    end
  end
end
