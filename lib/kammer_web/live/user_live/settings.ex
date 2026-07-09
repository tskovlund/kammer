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
        <.input
          field={@settings_form[:digest_frequency]}
          type="select"
          label={gettext("Email digest")}
          options={[
            {gettext("Off"), "off"},
            {gettext("Daily"), "daily"},
            {gettext("Weekly (Mondays)"), "weekly"}
          ]}
        />

        <div class="divider" />

        <p class="pb-2 text-sm text-base-content/60">
          {gettext(
            "Optional — shown to the communities you're in. Contact fields stay hidden unless you choose otherwise."
          )}
        </p>
        <.input field={@settings_form[:bio]} type="textarea" label={gettext("Bio")} rows="3" />
        <.input field={@settings_form[:pronouns]} type="text" label={gettext("Pronouns")} />

        <div class="flex items-end gap-2">
          <.input field={@settings_form[:contact_phone]} type="text" label={gettext("Phone")} />
          <.input
            field={@settings_form[:contact_phone_visibility]}
            type="select"
            label={gettext("Visible to")}
            options={visibility_options()}
          />
        </div>
        <div class="flex items-end gap-2">
          <.input
            field={@settings_form[:contact_email]}
            type="email"
            label={gettext("Public contact email")}
          />
          <.input
            field={@settings_form[:contact_email_visibility]}
            type="select"
            label={gettext("Visible to")}
            options={visibility_options()}
          />
        </div>
        <div class="flex items-end gap-2">
          <.input field={@settings_form[:contact_note]} type="text" label={gettext("Other contact")} />
          <.input
            field={@settings_form[:contact_note_visibility]}
            type="select"
            label={gettext("Visible to")}
            options={visibility_options()}
          />
        </div>

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

      <div class="divider" />

      <%!-- Data rights (SPEC §12) --%>
      <section class="rounded-box border border-base-200 p-4">
        <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Your data")}
        </h2>
        <p class="pb-3 text-sm text-base-content/70">
          {gettext(
            "Download everything this instance stores about you — profile, posts, comments, answers, and your uploaded files — as one zip."
          )}
        </p>
        <a href={~p"/users/settings/export"} class="btn btn-outline btn-sm" id="export-data">
          {gettext("Download my data")}
        </a>

        <p class="pb-3 pt-6 text-sm text-base-content/70">
          {gettext(
            "Deleting your account removes your identity, sessions, RSVPs, signups, and votes immediately. Your posts and comments stay, shown as \"Deleted user\" — the shared history belongs to the groups. Files you uploaded to shared spaces also stay, without your name."
          )}
        </p>
        <.button
          id="delete-account"
          phx-click="delete_account"
          data-confirm={
            gettext(
              "Delete your account? This cannot be undone. Download your data first if you want it."
            )
          }
          class="btn btn-outline btn-sm text-error"
        >
          {gettext("Delete my account")}
        </.button>
      </section>
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
        case Accounts.deliver_user_update_email_instructions(
               Ecto.Changeset.apply_action!(changeset, :insert),
               user.email,
               &url(~p"/users/settings/confirm-email/#{&1}")
             ) do
          {:error, :rate_limited} ->
            error =
              gettext("Too many email-change requests. Please wait a while and try again.")

            {:noreply, socket |> put_flash(:error, error)}

          _sent ->
            info =
              gettext("A link to confirm your email change has been sent to the new address.")

            {:noreply, socket |> put_flash(:info, info)}
        end

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

  def handle_event("delete_account", _params, socket) do
    :ok = Kammer.Gdpr.delete_account(socket.assigns.current_scope.user)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Your account has been deleted."))
     |> redirect(to: ~p"/")}
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

  defp visibility_options do
    [
      {gettext("Nobody (hidden)"), "hidden"},
      {gettext("Community members"), "members"},
      {gettext("Admins only"), "admins"}
    ]
  end
end
