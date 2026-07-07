defmodule KammerWeb.CommunityLive.CompleteProfile do
  @moduledoc """
  Fills in a community's required custom profile fields (SPEC §4)
  before a freshly-redeemed invite lands the member on their
  destination. Required fields hard-block here, at join time; a field
  made required after someone already joined never lands them back on
  this page — that case is a nag banner instead
  (`KammerWeb.CommunityLive.Home`), never a lockout.
  """

  use KammerWeb, :live_view

  alias Kammer.Communities

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {gettext("Before you continue")}
        <:subtitle>
          {gettext("%{community} asks for a few more details.", community: @active_community.name)}
        </:subtitle>
      </.header>

      <.form for={@form} id="complete-profile-form" phx-submit="save" class="space-y-4">
        <div :for={field <- @missing_fields}>
          <.input
            :if={field.field_type == :text}
            field={@form[field.id]}
            type="text"
            label={field.label}
            required
          />
          <.input
            :if={field.field_type == :single_select}
            field={@form[field.id]}
            type="select"
            label={field.label}
            options={field.options}
            prompt={gettext("Choose one")}
            required
          />
        </div>

        <.button variant="primary" phx-disable-with={gettext("Saving…")}>
          {gettext("Continue")}
        </.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    user = socket.assigns.current_scope.user
    community = socket.assigns.active_community
    missing_fields = Communities.missing_required_custom_fields(community, user)

    return_to =
      params["return_to"] || Map.get(session, "profile_return_to") ||
        ~p"/c/#{community.slug}"

    if missing_fields == [] do
      {:ok, push_navigate(socket, to: return_to)}
    else
      {:ok,
       socket
       |> assign(:missing_fields, missing_fields)
       |> assign(:return_to, return_to)
       |> assign(:form, to_form(%{}, as: "custom_field"))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"custom_field" => params}, socket) do
    user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    :ok = Communities.put_custom_field_values(user, community, params)

    case Communities.missing_required_custom_fields(community, user) do
      [] ->
        {:noreply, push_navigate(socket, to: socket.assigns.return_to)}

      still_missing ->
        {:noreply,
         socket
         |> assign(:missing_fields, still_missing)
         |> put_flash(:error, gettext("A few required fields are still empty."))}
    end
  end
end
