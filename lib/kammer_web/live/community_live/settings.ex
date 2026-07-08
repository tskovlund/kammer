defmodule KammerWeb.CommunityLive.Settings do
  @moduledoc """
  Community administration: branding (name, accent — retints instantly),
  policies (real-names statement, instance listing), and community-wide
  invite links.
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents, only: [invite_list: 1]

  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Invitations
  alias KammerWeb.InviteEventHandlers

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
      current_tab={:settings}
    >
      <.header>
        {gettext("Community settings")}
        <:subtitle>{@active_community.name}</:subtitle>
      </.header>

      <.form for={@form} id="community_settings_form" phx-submit="save" phx-change="validate">
        <.input field={@form[:name]} type="text" label={gettext("Name")} required />
        <.input field={@form[:description]} type="textarea" label={gettext("Description")} />
        <.input field={@form[:accent_color]} type="color" label={gettext("Accent color")} />
        <.input
          field={@form[:default_locale]}
          type="select"
          label={gettext("Default language")}
          options={[{gettext("English"), "en"}, {gettext("Danish"), "da"}]}
        />
        <.input
          field={@form[:listed_on_instance]}
          type="checkbox"
          label={gettext("List this community on the instance landing page")}
        />
        <.input
          field={@form[:require_real_names]}
          type="checkbox"
          label={gettext("Ask members to use their full, real name")}
        />
        <p class="text-sm text-base-content/60">
          {gettext(
            "The real-names policy is shown when joining; it is a statement, not technically verified."
          )}
        </p>

        <.button variant="primary" phx-disable-with={gettext("Saving...")}>
          {gettext("Save settings")}
        </.button>
      </.form>

      <section class="pt-6">
        <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Community invite links")}
        </h2>
        <.invite_list invites={@invites} />
      </section>

      <section class="pt-6">
        <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Invite by email")}
        </h2>
        <.form for={@email_invite_form} id="email_invite_form" phx-submit="email_invite">
          <div class="flex gap-2">
            <.input
              field={@email_invite_form[:invited_email]}
              type="email"
              placeholder={gettext("name@example.com")}
            />
            <.button class="btn btn-primary">{gettext("Send invite")}</.button>
          </div>
        </.form>
      </section>

      <section class="pt-6">
        <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Member profile fields")}
        </h2>
        <p class="pb-3 text-sm text-base-content/60">
          {gettext(
            "Custom fields turn the member directory into a roster — \"Instrument\", \"Section\", \"Dietary needs\". Required fields block new members at join; making an existing field required only nags current members, it never locks them out."
          )}
        </p>

        <ul :if={@custom_fields != []} class="space-y-2 pb-3">
          <li
            :for={field <- @custom_fields}
            class="flex items-center gap-3 rounded-box border border-base-200 p-3 text-sm"
          >
            <div class="min-w-0 flex-1">
              <p class="truncate font-medium">{field.label}</p>
              <p class="text-xs text-base-content/50">
                {field_type_label(field.field_type)} · {visibility_label(field.visibility)}
                <span :if={field.required}>· {gettext("Required")}</span>
              </p>
            </div>
            <.button
              phx-click="toggle_required_custom_field"
              phx-value-id={field.id}
              class="btn btn-ghost btn-xs"
            >
              {if field.required, do: gettext("Make optional"), else: gettext("Make required")}
            </.button>
            <.button
              phx-click="delete_custom_field"
              phx-value-id={field.id}
              data-confirm={gettext("Delete this field and every member's answer to it?")}
              class="btn btn-ghost btn-xs text-error"
            >
              {gettext("Delete")}
            </.button>
          </li>
        </ul>

        <.form
          for={@custom_field_form}
          id="custom-field-form"
          phx-submit="add_custom_field"
          class="space-y-2 rounded-box border border-base-200 p-3"
        >
          <.input
            field={@custom_field_form[:label]}
            type="text"
            label={gettext("Field name")}
            required
          />
          <.input
            field={@custom_field_form[:field_type]}
            type="select"
            label={gettext("Type")}
            options={[
              {gettext("Text"), "text"},
              {gettext("Single choice"), "single_select"}
            ]}
          />
          <.input
            field={@custom_field_form[:options]}
            type="textarea"
            label={gettext("Choices (one per line, only used for single choice)")}
            rows="3"
          />
          <.input
            field={@custom_field_form[:visibility]}
            type="select"
            label={gettext("Visible to")}
            options={[
              {gettext("All members"), "members"},
              {gettext("Admins only"), "admins"}
            ]}
          />
          <.input
            field={@custom_field_form[:required]}
            type="checkbox"
            label={gettext("Required")}
          />
          <.button variant="primary" class="btn-sm" phx-disable-with={gettext("Adding…")}>
            {gettext("Add field")}
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    case Authorization.authorize(current_user, :manage_community, community) do
      :ok ->
        {:ok,
         socket
         |> assign(:form, to_form(Communities.change_community(community)))
         |> assign(:email_invite_form, to_form(%{"invited_email" => ""}, as: "invite"))
         |> assign(
           :custom_field_form,
           to_form(%{"label" => "", "field_type" => "text", "visibility" => "members"},
             as: "custom_field"
           )
         )
         |> load_invites(current_user)
         |> load_custom_fields()}

      {:error, :unauthorized} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You are not allowed to do that."))
         |> push_navigate(to: ~p"/c/#{community.slug}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"community" => community_params}, socket) do
    changeset =
      socket.assigns.active_community
      |> Communities.change_community(community_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"community" => community_params}, socket) do
    current_user = socket.assigns.current_scope.user

    # The slug is deliberately not editable here: stable public URLs (SPEC §3).
    community_params = Map.delete(community_params, "slug")

    case Communities.update_community(
           current_user,
           socket.assigns.active_community,
           community_params
         ) do
      {:ok, community} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Settings saved."))
         |> assign(:active_community, community)
         |> assign(:form, to_form(Communities.change_community(community)))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("create_invite", _params, socket) do
    InviteEventHandlers.handle_create_invite(
      socket,
      &Invitations.create_community_invite(&1, socket.assigns.active_community),
      fn socket -> load_invites(socket, socket.assigns.current_scope.user) end
    )
  end

  def handle_event("email_invite", %{"invite" => %{"invited_email" => invited_email}}, socket) do
    current_user = socket.assigns.current_scope.user

    case Invitations.create_community_invite(current_user, socket.assigns.active_community, %{
           "invited_email" => invited_email,
           "max_uses" => 1
         }) do
      {:ok, _invite} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Invitation sent to %{email}.", email: invited_email))
         |> assign(:email_invite_form, to_form(%{"invited_email" => ""}, as: "invite"))
         |> load_invites(current_user)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not send that invitation."))}
    end
  end

  def handle_event("revoke_invite", %{"id" => invite_id}, socket) do
    InviteEventHandlers.handle_revoke_invite(
      socket,
      invite_id,
      fn socket -> load_invites(socket, socket.assigns.current_scope.user) end
    )
  end

  def handle_event("add_custom_field", %{"custom_field" => params}, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community
    params = Map.update(params, "options", [], &split_options/1)

    case Communities.create_custom_field(current_user, community, params) do
      {:ok, _field} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Field added."))
         |> assign(
           :custom_field_form,
           to_form(%{"label" => "", "field_type" => "text", "visibility" => "members"},
             as: "custom_field"
           )
         )
         |> load_custom_fields()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :custom_field_form, to_form(changeset, as: "custom_field"))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("toggle_required_custom_field", %{"id" => field_id}, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community
    field = Enum.find(socket.assigns.custom_fields, &(&1.id == field_id))

    if field do
      case Communities.update_custom_field(current_user, community, field, %{
             "required" => !field.required
           }) do
        {:ok, _updated} ->
          {:noreply, load_custom_fields(socket)}

        {:error, :unauthorized} ->
          {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_custom_field", %{"id" => field_id}, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community
    field = Enum.find(socket.assigns.custom_fields, &(&1.id == field_id))

    if field do
      case Communities.delete_custom_field(current_user, community, field) do
        {:ok, _deleted} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Field deleted."))
           |> load_custom_fields()}

        {:error, :unauthorized} ->
          {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
      end
    else
      {:noreply, socket}
    end
  end

  defp split_options(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp load_invites(socket, current_user) do
    invites =
      case Invitations.list_invites(current_user, socket.assigns.active_community) do
        {:ok, invites} -> invites
        {:error, :unauthorized} -> []
      end

    assign(socket, :invites, invites)
  end

  defp load_custom_fields(socket) do
    assign(
      socket,
      :custom_fields,
      Communities.list_custom_fields(socket.assigns.active_community)
    )
  end

  defp field_type_label(:text), do: gettext("Text")
  defp field_type_label(:single_select), do: gettext("Single choice")

  defp visibility_label(:members), do: gettext("All members")
  defp visibility_label(:admins), do: gettext("Admins only")
end
