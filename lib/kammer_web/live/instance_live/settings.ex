defmodule KammerWeb.InstanceLive.Settings do
  @moduledoc """
  Operator-only instance settings (SPEC §9 / ADR 0011): today, just the
  content-minimized email toggle. Other instance settings
  (`instance_name`, `community_creation_policy`, `storage_policy`) are
  still set once by the setup wizard and have no edit surface yet.
  """

  use KammerWeb, :live_view

  alias Kammer.Authorization
  alias Kammer.Communities

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {gettext("Instance settings")}
        <:subtitle>{gettext("Operator-only. Applies to the whole instance.")}</:subtitle>
      </.header>

      <.form
        for={@form}
        id="instance-settings-form"
        phx-change="validate"
        phx-submit="save"
        class="max-w-2xl space-y-4"
      >
        <div class="rounded-box border border-base-300 p-4">
          <.input
            field={@form[:content_minimized_emails]}
            type="checkbox"
            label={gettext("Content-minimized email mode")}
          />
          <p class="mt-1 text-sm text-base-content/60">
            {gettext(
              "Digest emails carry only counts and a link — no post text or author names. Auth and RSVP emails are already minimal and are unaffected. Off by default; most communities prefer the extra context."
            )}
          </p>
        </div>

        <.button variant="primary" phx-disable-with={gettext("Saving…")}>
          {gettext("Save")}
        </.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if Authorization.instance_operator?(user) do
      settings = Communities.get_instance_settings()

      {:ok,
       socket
       |> assign(:page_title, gettext("Instance settings"))
       |> assign(:form, to_form(Communities.change_instance_settings(settings)))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Only instance operators can view instance settings."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"instance_settings" => params}, socket) do
    settings = Communities.get_instance_settings()

    form =
      settings
      |> Communities.change_instance_settings(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"instance_settings" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Communities.update_instance_settings(user, params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved."))
         |> assign(:form, to_form(Communities.change_instance_settings(settings)))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, gettext("Only instance operators can edit instance settings."))}
    end
  end
end
