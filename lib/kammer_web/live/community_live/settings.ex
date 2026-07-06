defmodule KammerWeb.CommunityLive.Settings do
  @moduledoc """
  Community administration: branding (name, accent — retints instantly),
  policies (real-names statement, instance listing), and community-wide
  invite links.
  """

  use KammerWeb, :live_view

  alias Kammer.Authorization
  alias Kammer.Communities
  alias Kammer.Invitations

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
        <ul :if={@invites != []} class="space-y-2 pb-3">
          <li
            :for={invite <- @invites}
            class="flex items-center gap-3 rounded-box border border-base-200 p-3 text-sm"
          >
            <code class="min-w-0 flex-1 truncate">{url(~p"/invite/#{invite.token}")}</code>
            <span class="whitespace-nowrap text-base-content/50">{invite.use_count}</span>
            <.button phx-click="revoke_invite" phx-value-id={invite.id} class="btn btn-ghost btn-xs">
              {gettext("Revoke")}
            </.button>
          </li>
        </ul>
        <.button phx-click="create_invite" class="btn btn-ghost btn-sm">
          <.icon name="hero-link" class="size-4" /> {gettext("Create invite link")}
        </.button>
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
         |> load_invites(current_user)}

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
    current_user = socket.assigns.current_scope.user

    case Invitations.create_community_invite(current_user, socket.assigns.active_community) do
      {:ok, _invite} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Invite link created."))
         |> load_invites(current_user)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
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
    current_user = socket.assigns.current_scope.user
    invite = Enum.find(socket.assigns.invites, fn invite -> invite.id == invite_id end)

    if invite do
      case Invitations.revoke_invite(current_user, invite) do
        {:ok, _revoked} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Invite revoked."))
           |> load_invites(current_user)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
      end
    else
      {:noreply, socket}
    end
  end

  defp load_invites(socket, current_user) do
    invites =
      case Invitations.list_invites(current_user, socket.assigns.active_community) do
        {:ok, invites} -> invites
        {:error, :unauthorized} -> []
      end

    assign(socket, :invites, invites)
  end
end
