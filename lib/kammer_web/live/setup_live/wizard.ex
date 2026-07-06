defmodule KammerWeb.SetupLive.Wizard do
  @moduledoc """
  First-run setup wizard (SPEC §13, ADR 0010). Token-gated (the token is
  printed to the server logs at boot), it collects whatever the
  environment did not provide: operator account, instance settings, the
  first community and group, and an optional demo community. Completion
  sends the operator their first magic link — a live SMTP test — and
  locks the wizard forever.
  """

  use KammerWeb, :live_view

  alias Kammer.Communities
  alias Kammer.Setup

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <.header>
          {gettext("Set up your instance")}
          <:subtitle>{step_subtitle(@step)}</:subtitle>
        </.header>

        <ul class="steps w-full text-xs">
          <li class={["step", step_reached?(@step, :token) && "step-primary"]}>
            {gettext("Token")}
          </li>
          <li class={["step", step_reached?(@step, :instance) && "step-primary"]}>
            {gettext("Instance")}
          </li>
          <li class={["step", step_reached?(@step, :community) && "step-primary"]}>
            {gettext("Community")}
          </li>
          <li class={["step", step_reached?(@step, :done) && "step-primary"]}>
            {gettext("Done")}
          </li>
        </ul>

        <div :if={@step == :token}>
          <form id="setup-token-form" phx-submit="verify_token" class="space-y-4">
            <.input
              type="text"
              name="token"
              value=""
              label={gettext("Setup token")}
              placeholder={gettext("Paste the token from the server logs")}
              autocomplete="off"
              required
            />
            <p class="text-sm text-base-content/60">
              {gettext(
                "The token was printed to the server logs when this instance started. It proves you operate the server."
              )}
            </p>
            <.button variant="primary" class="w-full">{gettext("Continue")}</.button>
          </form>
        </div>

        <div :if={@step == :instance}>
          <form id="setup-instance-form" phx-submit="save_instance" class="space-y-4">
            <.input
              type="email"
              name="operator_email"
              value={@operator_email}
              label={gettext("Your email (instance operator)")}
              required
            />
            <.input
              type="text"
              name="operator_display_name"
              value={@operator_display_name}
              label={gettext("Your display name")}
              required
            />
            <.input
              type="text"
              name="instance_name"
              value={@settings.instance_name}
              label={gettext("Instance name")}
              placeholder="Kammer"
            />
            <.input
              type="select"
              name="default_locale"
              value={@settings.default_locale}
              label={gettext("Default language")}
              options={[{gettext("English"), "en"}, {gettext("Danish"), "da"}]}
            />
            <.input
              type="select"
              name="community_creation_policy"
              value={@settings.community_creation_policy}
              label={gettext("Who may create communities?")}
              options={[
                {gettext("Only instance operators"), "operators_only"},
                {gettext("Any signed-in user"), "any_user"}
              ]}
            />
            <.button variant="primary" class="w-full">{gettext("Continue")}</.button>
          </form>
        </div>

        <div :if={@step == :community}>
          <form id="setup-community-form" phx-submit="complete" class="space-y-4">
            <.input
              type="text"
              name="community_name"
              value=""
              label={gettext("Your first community's name")}
              required
            />
            <.input
              type="text"
              name="community_slug"
              value=""
              label={gettext("Community URL slug")}
              placeholder={gettext("e.g. our-club")}
              required
            />
            <.input
              type="color"
              name="accent_color"
              value="#3E6B48"
              label={gettext("Accent color")}
            />
            <.input
              type="text"
              name="group_name"
              value={gettext("General")}
              label={gettext("Your first group's name")}
              required
            />
            <.input
              type="text"
              name="group_slug"
              value="general"
              label={gettext("Group URL slug")}
              required
            />
            <label class="flex items-start gap-3 rounded-box border border-base-200 p-4">
              <input type="hidden" name="demo_data" value="false" />
              <input
                type="checkbox"
                name="demo_data"
                value="true"
                class="checkbox checkbox-sm mt-0.5"
              />
              <span class="text-sm">
                <span class="font-medium">{gettext("Create a demo community")}</span>
                <br />
                <span class="text-base-content/60">
                  {gettext(
                    "A small sandbox with example posts, a poll, and an event. Removable with one click later."
                  )}
                </span>
              </span>
            </label>
            <.button variant="primary" class="w-full" phx-disable-with={gettext("Setting up…")}>
              {gettext("Finish setup")}
            </.button>
          </form>
        </div>

        <div :if={@step == :done} class="space-y-6">
          <div class="rounded-box border border-base-200 p-6 text-center">
            <.icon name="hero-check-circle" class="mx-auto size-10 text-success" />
            <h2 class="mt-2 text-lg font-semibold">{gettext("Your instance is ready")}</h2>
            <p class="mt-1 text-sm text-base-content/70">
              {gettext(
                "We emailed you a sign-in link — receiving it confirms your email delivery works."
              )}
            </p>
          </div>

          <div class="space-y-2">
            <h3 class="text-sm font-medium uppercase tracking-wide text-base-content/50">
              {gettext("Invite your members")}
            </h3>
            <p class="break-all rounded-field bg-base-200 p-3 font-mono text-sm" id="invite-url">
              {@invite_url}
            </p>
            <p class="text-sm text-base-content/60">
              {gettext("Anyone with this link can join %{community}.", community: @community_slug)}
            </p>
          </div>

          <div class="rounded-box border border-base-200 p-4 text-sm text-base-content/70">
            {gettext(
              "Before opening the doors: publish your privacy policy and imprint. Built-in templates are ready to adapt."
            )}
            <div class="mt-2 flex gap-3">
              <.link navigate={~p"/legal/privacy/edit"} class="link">
                {gettext("Privacy policy")}
              </.link>
              <.link navigate={~p"/legal/imprint/edit"} class="link">{gettext("Imprint")}</.link>
            </div>
          </div>

          <.link navigate={~p"/"} class="btn btn-primary w-full">
            {gettext("Go to your instance")}
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if Setup.completed?() do
      {:ok,
       socket
       |> put_flash(:info, gettext("This instance is already set up."))
       |> push_navigate(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, gettext("Setup"))
       |> assign(:step, :token)
       |> assign(:settings, Communities.get_instance_settings())
       |> assign(:operator_email, System.get_env("OPERATOR_EMAIL") || "")
       |> assign(:operator_display_name, "")
       |> assign(:instance_params, %{})
       |> assign(:invite_url, nil)
       |> assign(:community_slug, nil)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("verify_token", %{"token" => token}, socket) do
    if Setup.valid_token?(String.trim(token)) do
      {:noreply, assign(socket, :step, :instance)}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("That token doesn't match. Check the server logs for the current one.")
       )}
    end
  end

  def handle_event("save_instance", params, socket) do
    operator_email = String.trim(params["operator_email"] || "")

    if operator_email == "" do
      {:noreply, put_flash(socket, :error, gettext("Enter your email address."))}
    else
      {:noreply,
       socket
       |> assign(:operator_email, operator_email)
       |> assign(:operator_display_name, String.trim(params["operator_display_name"] || ""))
       |> assign(
         :instance_params,
         Map.take(params, ["instance_name", "default_locale", "community_creation_policy"])
       )
       |> assign(:step, :community)}
    end
  end

  def handle_event("complete", params, socket) do
    attrs = %{
      "operator" => %{
        "email" => socket.assigns.operator_email,
        "display_name" => socket.assigns.operator_display_name
      },
      "instance" => socket.assigns.instance_params,
      "community" => %{
        "name" => params["community_name"],
        "slug" => params["community_slug"],
        "accent_color" => params["accent_color"],
        "default_locale" => socket.assigns.instance_params["default_locale"]
      },
      "group" => %{
        "name" => params["group_name"],
        "slug" => params["group_slug"]
      },
      "demo_data" => params["demo_data"]
    }

    case Setup.complete(attrs, &url(~p"/users/log-in/#{&1}")) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:step, :done)
         |> assign(:invite_url, url(~p"/invite/#{result.invite_token}"))
         |> assign(:community_slug, result.community_slug)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, completion_error(reason))}
    end
  end

  defp completion_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end

  defp completion_error(:already_completed),
    do: gettext("This instance is already set up.")

  defp completion_error(:operator_email_required),
    do: gettext("Enter your email address.")

  defp completion_error(_other),
    do: gettext("Setup failed — check the values and try again.")

  defp step_subtitle(:token), do: gettext("Prove you operate this server.")

  defp step_subtitle(:instance),
    do: gettext("Name the instance and create your operator account.")

  defp step_subtitle(:community), do: gettext("Create your first community and group.")
  defp step_subtitle(:done), do: gettext("Everything is in place.")

  @steps [:token, :instance, :community, :done]

  defp step_reached?(current, step) do
    Enum.find_index(@steps, &(&1 == current)) >= Enum.find_index(@steps, &(&1 == step))
  end
end
