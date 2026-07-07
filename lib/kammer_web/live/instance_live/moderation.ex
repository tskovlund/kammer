defmodule KammerWeb.InstanceLive.Moderation do
  @moduledoc """
  Operator-only instance-wide bans (SPEC §11): a block list keyed on
  email, enforced by `Communities.add_member/3` ahead of the
  per-community ban — for people who should not rejoin *any* community
  on this instance.
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

  alias Kammer.Authorization
  alias Kammer.Moderation
  alias Kammer.Moderation.InstanceBan

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {gettext("Instance moderation")}
        <:subtitle>
          {gettext("Operator-only. Blocks rejoin on every community, not just one.")}
        </:subtitle>
      </.header>

      <.form for={@form} id="instance-ban-form" phx-submit="ban" class="max-w-xl space-y-4">
        <.input field={@form[:email]} type="email" label={gettext("Email")} required />
        <.input field={@form[:reason]} type="text" label={gettext("Reason (optional)")} />
        <.button variant="primary" phx-disable-with={gettext("Banning…")}>
          {gettext("Ban instance-wide")}
        </.button>
      </.form>

      <section class="pt-6">
        <h2 class="pb-2 text-sm font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Active instance bans")}
        </h2>
        <div
          :for={ban <- @bans}
          class="flex items-center gap-3 rounded-box border border-base-200 p-3"
        >
          <div class="min-w-0 flex-1">
            <p class="truncate font-medium">{ban.email}</p>
            <p class="text-xs text-base-content/60">
              {Calendar.strftime(ban.inserted_at, "%d %b %Y")}
              <span :if={ban.reason}>· {ban.reason}</span>
            </p>
          </div>
          <.button
            id={"unban-instance-#{ban.id}"}
            phx-click="unban"
            phx-value-id={ban.id}
            data-confirm={gettext("Lift this instance ban?")}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Lift ban")}
          </.button>
        </div>

        <.empty_state
          :if={@bans == []}
          icon="hero-shield-check"
          headline={gettext("No instance bans")}
          description={gettext("Nobody is blocked instance-wide right now.")}
        />
      </section>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if Authorization.instance_operator?(user) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Instance moderation"))
       |> assign(:form, blank_form())
       |> assign(:bans, Moderation.list_instance_bans(user))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Only instance operators can view instance moderation."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("ban", %{"instance_ban" => params}, socket) do
    user = socket.assigns.current_scope.user
    reason = normalize_reason(params["reason"])

    case Moderation.ban_instance(user, params["email"] || "", reason) do
      {:ok, _ban} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Banned instance-wide."))
         |> assign(:form, blank_form())
         |> assign(:bans, Moderation.list_instance_bans(user))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :instance_ban))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event("unban", %{"id" => ban_id}, socket) do
    user = socket.assigns.current_scope.user

    with %InstanceBan{} = ban <- Kammer.Repo.get(InstanceBan, ban_id),
         {:ok, _ban} <- Moderation.unban_instance(user, ban) do
      {:noreply, assign(socket, :bans, Moderation.list_instance_bans(user))}
    else
      _error -> {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  defp blank_form, do: to_form(%{"email" => "", "reason" => ""}, as: :instance_ban)

  defp normalize_reason(nil), do: nil

  defp normalize_reason(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
