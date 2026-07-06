defmodule KammerWeb.CommunityLive.New do
  @moduledoc """
  Community creation, gated by the instance policy (SPEC §3: operators
  only / any user). The creator becomes the community Owner.
  """

  use KammerWeb, :live_view

  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Communities.Community

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {gettext("New community")}
        <:subtitle>
          {gettext("A community is home to its groups, events, files, and members.")}
        </:subtitle>
      </.header>

      <.form for={@form} id="community_form" phx-submit="save" phx-change="validate">
        <.input field={@form[:name]} type="text" label={gettext("Name")} required />
        <.input
          field={@form[:slug]}
          type="text"
          label={gettext("Web address")}
          placeholder="taagekammeret"
          required
        />
        <.input field={@form[:description]} type="textarea" label={gettext("Description")} />
        <.input field={@form[:accent_color]} type="color" label={gettext("Accent color")} />
        <.input
          field={@form[:default_locale]}
          type="select"
          label={gettext("Default language")}
          options={[{gettext("English"), "en"}, {gettext("Danish"), "da"}]}
        />

        <.button variant="primary" phx-disable-with={gettext("Creating...")}>
          {gettext("Create community")}
        </.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_scope.user
    settings = Communities.get_instance_settings()

    if Authorization.can_create_community?(current_user, settings) do
      {:ok, assign(socket, :form, to_form(Communities.change_community(%Community{})))}
    else
      {:ok,
       socket
       |> put_flash(
         :error,
         gettext("Only instance operators may create communities on this instance.")
       )
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"community" => community_params}, socket) do
    changeset =
      %Community{}
      |> Communities.change_community(suggest_slug(community_params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"community" => community_params}, socket) do
    current_user = socket.assigns.current_scope.user

    case Communities.create_community(current_user, community_params) do
      {:ok, community} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Community created — welcome home."))
         |> push_navigate(to: ~p"/c/#{community.slug}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not allowed to do that."))
         |> push_navigate(to: ~p"/")}
    end
  end

  defp suggest_slug(%{"name" => name, "slug" => ""} = params) when is_binary(name) do
    suggested =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    Map.put(params, "slug", suggested)
  end

  defp suggest_slug(params), do: params
end
