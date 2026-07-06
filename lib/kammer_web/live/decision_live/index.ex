defmodule KammerWeb.DecisionLive.Index do
  @moduledoc """
  A group's decisions register (issue #43): every motion, its outcome,
  and a link to the post that carried the text and the vote —
  chronological, minutes-grade institutional memory.
  """

  use KammerWeb, :live_view

  import KammerWeb.KammerComponents

  alias Kammer.Authorization
  alias Kammer.Decisions
  alias Kammer.Decisions.Decision
  alias Kammer.Groups

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
        {gettext("Decisions")}
        <:subtitle>{@group.name}</:subtitle>
      </.header>

      <%!-- Raise a motion --%>
      <form
        :if={@can_propose?}
        id="new-decision-form"
        phx-submit="propose"
        class="space-y-2 rounded-box border border-base-200 p-4"
      >
        <label class="flex flex-col gap-1 text-xs text-base-content/60">
          {gettext("The motion")}
          <input
            type="text"
            name="decision[title]"
            required
            placeholder={gettext("e.g. Raise the yearly membership fee to 250 kr.")}
            class="input input-sm"
          />
        </label>
        <label class="flex flex-col gap-1 text-xs text-base-content/60">
          {gettext("Background (optional, Markdown)")}
          <textarea
            name="decision[motion_markdown]"
            rows="2"
            placeholder={gettext("Why, what, and what it costs…")}
            class="textarea textarea-sm"
          ></textarea>
        </label>
        <div class="flex flex-wrap items-center gap-3">
          <label class="flex cursor-pointer items-center gap-1.5 text-sm">
            <input
              type="checkbox"
              name="decision[with_vote]"
              value="true"
              checked
              class="checkbox checkbox-xs"
            />
            {gettext("Open a For / Against / Abstain vote in the feed")}
          </label>
          <button type="submit" class="btn btn-primary btn-sm">
            {gettext("Raise the motion")}
          </button>
        </div>
      </form>

      <section class="space-y-2">
        <div
          :for={decision <- @decisions}
          id={"decision-#{decision.id}"}
          class="rounded-box border border-base-200 p-4"
        >
          <div class="flex flex-wrap items-center gap-2">
            <p class="min-w-0 flex-1 font-medium">{decision.title}</p>
            <.outcome_badge decision={decision} />
          </div>
          <p class="pt-1 text-xs text-base-content/60">
            {Calendar.strftime(decision.inserted_at, "%d %b %Y")}
            <span :if={Decision.decided?(decision) and decision.decided_by_user}>
              · {gettext("recorded by %{name}", name: decision.decided_by_user.display_name)}
            </span>
            ·
            <.link
              navigate={
                ~p"/c/#{@active_community.slug}/g/#{@group.slug}" <> "#post-#{decision.post_id}"
              }
              class="link"
            >
              {gettext("motion & vote")}
            </.link>
          </p>
          <p :if={decision.outcome_note} class="pt-1 text-sm text-base-content/80">
            {decision.outcome_note}
          </p>

          <form
            :if={@can_record? and not Decision.decided?(decision)}
            id={"record-outcome-#{decision.id}"}
            phx-submit="record_outcome"
            class="flex flex-wrap items-center gap-2 pt-3"
          >
            <input type="hidden" name="decision_id" value={decision.id} />
            <select name="outcome" class="select select-sm">
              <option value="adopted">{gettext("Adopted")}</option>
              <option value="rejected">{gettext("Rejected")}</option>
              <option value="noted">{gettext("Noted")}</option>
            </select>
            <input
              type="text"
              name="outcome_note"
              placeholder={gettext("Note for the record (optional)")}
              class="input input-sm flex-1"
            />
            <button type="submit" class="btn btn-outline btn-sm">
              {gettext("Record outcome")}
            </button>
          </form>
        </div>

        <.empty_state
          :if={@decisions == []}
          icon="hero-scale"
          headline={gettext("No decisions yet")}
          description={gettext("Raise a motion — the register remembers it forever.")}
        />
      </section>
    </Layouts.app>
    """
  end

  attr :decision, Decision, required: true

  defp outcome_badge(assigns) do
    ~H"""
    <span :if={@decision.outcome == :adopted} class="badge badge-success badge-sm">
      {gettext("Adopted")}
    </span>
    <span :if={@decision.outcome == :rejected} class="badge badge-error badge-sm">
      {gettext("Rejected")}
    </span>
    <span :if={@decision.outcome == :noted} class="badge badge-ghost badge-sm">
      {gettext("Noted")}
    </span>
    <span :if={is_nil(@decision.outcome)} class="badge badge-warning badge-sm">
      {gettext("Open")}
    </span>
    """
  end

  @impl Phoenix.LiveView
  def mount(%{"group_slug" => group_slug}, _session, socket) do
    current_user = socket.assigns.current_scope.user
    community = socket.assigns.active_community

    with {:ok, group} <- Groups.fetch_viewable_group(current_user, community, group_slug),
         :ok <- Authorization.feature_gate(group, :decisions) do
      {:ok,
       socket
       |> assign(:group, group)
       |> assign(:can_propose?, Authorization.can?(current_user, :post_in_group, group))
       |> assign(:can_record?, Authorization.can?(current_user, :moderate_group, group))
       |> reload()}
    else
      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Not found."))
         |> push_navigate(to: ~p"/c/#{community.slug}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("propose", %{"decision" => params}, socket) do
    current_user = socket.assigns.current_scope.user

    case Decisions.create_decision(current_user, socket.assigns.group, params,
           with_vote: params["with_vote"] == "true"
         ) do
      {:ok, _decision} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Motion raised — the vote is open in the feed."))
         |> reload()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("Please give the motion a title."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event(
        "record_outcome",
        %{"decision_id" => decision_id, "outcome" => outcome} = params,
        socket
      ) do
    current_user = socket.assigns.current_scope.user

    with %Decision{} = decision <- Kammer.Repo.get(Decision, decision_id),
         {:ok, _decision} <-
           Decisions.record_outcome(current_user, decision, %{
             "outcome" => outcome,
             "outcome_note" => params["outcome_note"]
           }) do
      {:noreply, reload(socket)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  defp reload(socket) do
    assign(socket, :decisions, Decisions.list_decisions(socket.assigns.group))
  end
end
