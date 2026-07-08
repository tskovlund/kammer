defmodule KammerWeb.KammerComponents do
  @moduledoc """
  Kammer-specific UI components (SPEC §21): deterministic avatars,
  designed empty states, and small shared pieces of the design language.
  """

  use KammerWeb, :html

  alias Kammer.Accounts.User
  alias Kammer.Communities.Community

  @doc """
  Deterministic avatar for a user: initials on a stable color derived from
  the user id (SPEC §4 — feeds stay scannable without uploads).
  """
  attr :user, User, required: true
  attr :size_class, :string, default: "size-9"
  attr :text_class, :string, default: "text-sm"

  @spec user_avatar(map()) :: Phoenix.LiveView.Rendered.t()
  def user_avatar(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex shrink-0 select-none items-center justify-center rounded-full font-medium text-white",
        @size_class,
        @text_class
      ]}
      style={"background-color: #{stable_color(@user.id)}"}
      aria-hidden="true"
    >
      {initials(@user.display_name)}
    </span>
    """
  end

  @doc """
  Deterministic avatar tile for a community, tinted with its accent.
  """
  attr :community, Community, required: true
  attr :size_class, :string, default: "size-9"
  attr :text_class, :string, default: "text-sm"
  attr :active, :boolean, default: false

  @spec community_avatar(map()) :: Phoenix.LiveView.Rendered.t()
  def community_avatar(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex shrink-0 select-none items-center justify-center rounded-lg font-semibold text-white",
        @size_class,
        @text_class,
        @active && "ring-2 ring-offset-2 ring-offset-base-100 ring-[var(--accent,#3E6B48)]"
      ]}
      style={"background-color: #{community_color(@community)}"}
      aria-hidden="true"
    >
      {initials(@community.name)}
    </span>
    """
  end

  @doc """
  Designed empty state (SPEC §1: the app must feel finished, not
  scaffolded). Icon, headline, supporting line, optional action slot.
  """
  attr :icon, :string, required: true
  attr :headline, :string, required: true
  attr :description, :string, default: nil
  slot :action

  @spec empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center gap-3 rounded-box border border-dashed border-base-300 px-6 py-16 text-center">
      <span class={["size-10 text-base-content/30", @icon]} aria-hidden="true"></span>
      <p class="font-medium">{@headline}</p>
      <p :if={@description} class="max-w-sm text-sm text-base-content/60">{@description}</p>
      <div :if={@action != []} class="mt-2">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  @doc """
  The "report to moderators" dialog (SPEC §11), shared by every page
  that can report a post or comment: group feed, event, and
  assignment pages. Pairs with `KammerWeb.ReportHandlers`, which owns
  the `start_report` / `cancel_report` / `submit_report` events this
  markup emits — the host LiveView just needs a `reporting` assign.
  """
  attr :reporting, :map, default: nil

  @spec report_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def report_modal(assigns) do
    ~H"""
    <dialog :if={@reporting} open class="modal modal-open" phx-click="cancel_report">
      <div class="modal-box" phx-click={JS.exec("phx-noop")}>
        <h3 class="pb-2 font-semibold">{gettext("Report to the moderators")}</h3>
        <form id="report-form" phx-submit="submit_report" class="space-y-3">
          <textarea
            name="reason"
            rows="3"
            required
            placeholder={gettext("What's wrong? The moderators see exactly what you write.")}
            class="textarea w-full"
          ></textarea>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="cancel_report" class="btn btn-ghost btn-sm">
              {gettext("Cancel")}
            </button>
            <.button variant="primary" class="btn-sm">{gettext("Send report")}</.button>
          </div>
        </form>
      </div>
    </dialog>
    """
  end

  @doc """
  Badge naming a group's visibility preset, translated.
  """
  attr :visibility, :atom, required: true

  @spec visibility_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def visibility_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-sm">{visibility_label(@visibility)}</span>
    """
  end

  @doc """
  Translated label for a visibility preset.
  """
  @spec visibility_label(atom()) :: String.t()
  def visibility_label(:private), do: gettext("Private")
  def visibility_label(:community), do: gettext("Community")
  def visibility_label(:public_link), do: gettext("Link only")
  def visibility_label(:public_listed), do: gettext("Public")

  @doc """
  The invite-link list and "Create invite link" button shared by group
  and community settings: expects `phx-click="create_invite"` and
  `phx-click="revoke_invite" phx-value-id={invite.id}` handled by the
  host LiveView.
  """
  attr :invites, :list, required: true

  @spec invite_list(map()) :: Phoenix.LiveView.Rendered.t()
  def invite_list(assigns) do
    ~H"""
    <ul :if={@invites != []} class="space-y-2 pb-3">
      <li
        :for={invite <- @invites}
        class="flex items-center gap-3 rounded-box border border-base-200 p-3 text-sm"
      >
        <code class="min-w-0 flex-1 truncate">{url(~p"/invite/#{invite.token}")}</code>
        <span class="whitespace-nowrap text-base-content/50">
          {invite_usage(invite)}
        </span>
        <.button phx-click="revoke_invite" phx-value-id={invite.id} class="btn btn-ghost btn-xs">
          {gettext("Revoke")}
        </.button>
      </li>
    </ul>
    <.button phx-click="create_invite" class="btn btn-ghost btn-sm">
      <.icon name="hero-link" class="size-4" /> {gettext("Create invite link")}
    </.button>
    """
  end

  defp invite_usage(invite) do
    used = gettext("%{count} used", count: invite.use_count)

    case invite.max_uses do
      nil -> used
      max_uses -> "#{invite.use_count}/#{max_uses}"
    end
  end

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
    |> case do
      "" -> "?"
      initials -> initials
    end
  end

  defp stable_color(id) do
    hue = :erlang.phash2(id, 360)
    "hsl(#{hue} 35% 38%)"
  end

  defp community_color(%Community{accent_color: accent_color}) do
    palette = Kammer.Design.AccentColor.palette(accent_color)
    palette.light.accent
  end
end
