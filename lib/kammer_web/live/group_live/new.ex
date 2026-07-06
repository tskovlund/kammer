defmodule KammerWeb.GroupLive.New do
  @moduledoc """
  Group creation: name, slug, description, the four visibility presets,
  join/posting/comment policies, approval queue — and the sealed flag,
  settable only here and irreversible (SPEC §3, ADR 0005).
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents, only: [visibility_label: 1]

  alias Kammer.Groups
  alias Kammer.Groups.Group

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_community={@active_community}
      member_communities={@member_communities}
      member_groups={@member_groups}
      community_relationship={@community_relationship}
      unread_notifications={@unread_notifications}
      current_tab={:groups}
    >
      <.header>
        {gettext("New group")}
        <:subtitle>{gettext("A band, a committee, a project — a room of its own.")}</:subtitle>
      </.header>

      <.form for={@form} id="group_form" phx-submit="save" phx-change="validate">
        <.input field={@form[:name]} type="text" label={gettext("Name")} required />
        <.input
          field={@form[:slug]}
          type="text"
          label={gettext("Web address")}
          placeholder="brass-section"
          required
        />
        <.input field={@form[:description]} type="textarea" label={gettext("Description")} />

        <.input
          field={@form[:visibility]}
          type="select"
          label={gettext("Visibility")}
          options={visibility_options()}
        />
        <.input
          field={@form[:join_policy]}
          type="select"
          label={gettext("Who can join")}
          options={[
            {gettext("Anyone in the community"), "open"},
            {gettext("Request with approval"), "request_approval"},
            {gettext("Invite only"), "invite_only"}
          ]}
        />
        <.input
          field={@form[:posting_policy]}
          type="select"
          label={gettext("Who can post")}
          options={[
            {gettext("All members"), "all_members"},
            {gettext("Admins only (announcement group)"), "admins_only"}
          ]}
        />
        <.input
          field={@form[:comment_policy]}
          type="select"
          label={gettext("Comments")}
          options={[
            {gettext("Members"), "members"},
            {gettext("Members and guests"), "members_and_guests"},
            {gettext("Off"), "off"}
          ]}
        />
        <.input
          field={@form[:approval_queue]}
          type="checkbox"
          label={gettext("Posts require admin approval")}
        />

        <div class="rounded-box border border-base-300 p-4">
          <.input field={@form[:sealed]} type="checkbox" label={gettext("Sealed group")} />
          <p class="mt-1 text-sm text-base-content/60">
            {gettext(
              "Sealed: hidden from community admins. The server operator can still technically access all data. This cannot be changed later."
            )}
          </p>
        </div>

        <.button variant="primary" phx-disable-with={gettext("Creating...")}>
          {gettext("Create group")}
        </.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    changeset = Groups.change_group(%Group{})
    {:ok, assign(socket, :form, to_form(changeset))}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"group" => group_params}, socket) do
    changeset =
      %Group{}
      |> Groups.change_group(suggest_slug(group_params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"group" => group_params}, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    case Groups.create_group(current_user, community, group_params) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Group created."))
         |> push_navigate(to: ~p"/c/#{community.slug}/g/#{group.slug}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not allowed to do that."))
         |> push_navigate(to: ~p"/c/#{community.slug}/groups")}
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

  defp visibility_options do
    Enum.map(Group.visibilities(), fn visibility ->
      {visibility_label(visibility), Atom.to_string(visibility)}
    end)
  end
end
