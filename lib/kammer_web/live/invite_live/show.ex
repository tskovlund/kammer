defmodule KammerWeb.InviteLive.Show do
  @moduledoc """
  Invite landing page (`/invite/:token`): shows what the invite is for.
  Signed-in users accept in place; visitors are sent through sign-in and
  come back via the accept endpoint (SPEC §3).
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

  alias Kammer.Invitations
  alias Kammer.Invitations.Invite

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%= if @invite do %>
        <div class="mx-auto max-w-md space-y-6 py-8 text-center">
          <.community_avatar
            community={@invite.community}
            size_class="mx-auto size-16"
            text_class="text-xl"
          />
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">
              {gettext("You're invited to %{name}", name: target_name(@invite))}
            </h1>
            <p :if={@invite.community.description} class="mt-2 text-base-content/70">
              {@invite.community.description}
            </p>
          </div>

          <p
            :if={@invite.community.require_real_names}
            class="rounded-box border border-base-300 p-3 text-sm text-base-content/70"
          >
            {gettext("This community asks members to use their full, real name.")}
          </p>

          <%= if @current_scope && @current_scope.user do %>
            <.button phx-click="accept" class="btn btn-primary btn-wide">
              {gettext("Accept invitation")}
            </.button>
          <% else %>
            <div class="space-y-2">
              <.link href={~p"/invite/#{@invite.token}/accept"} class="btn btn-primary btn-wide">
                {gettext("Sign in to accept")}
              </.link>
              <p class="text-sm text-base-content/60">
                {gettext("New here? You'll create an account with just your email.")}
              </p>
            </div>
          <% end %>
        </div>
      <% else %>
        <.empty_state
          icon="hero-envelope-open"
          headline={gettext("This invitation is no longer valid")}
          description={gettext("It may have expired, been revoked, or already been used up.")}
        >
          <:action>
            <.link navigate={~p"/"} class="btn btn-ghost btn-sm">{gettext("Go home")}</.link>
          </:action>
        </.empty_state>
      <% end %>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"token" => token}, _session, socket) do
    invite =
      case Invitations.get_invite_by_token(token) do
        %Invite{} = invite ->
          if Invite.redeemable?(invite, DateTime.utc_now(:second)), do: invite

        nil ->
          nil
      end

    {:ok, assign(socket, :invite, invite)}
  end

  @impl Phoenix.LiveView
  def handle_event("accept", _params, socket) do
    current_user = socket.assigns.current_scope.user
    invite = socket.assigns.invite

    case Invitations.redeem_invite(current_user, invite.token) do
      {:ok, redeemed} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Welcome to %{name}!", name: target_name(redeemed)))
         |> push_navigate(to: destination(redeemed))}

      {:error, :email_mismatch} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This invitation was sent to a different email address.")
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("This invitation is no longer valid."))}
    end
  end

  defp target_name(%Invite{group: nil, community: community}), do: community.name
  defp target_name(%Invite{group: group}), do: group.name

  defp destination(%Invite{group: nil, community: community}), do: ~p"/c/#{community.slug}"

  defp destination(%Invite{group: group, community: community}),
    do: ~p"/c/#{community.slug}/g/#{group.slug}"
end
