defmodule Kammer.Workers.EventReminderWorker do
  @moduledoc """
  Emails event reminders 24 hours before the start (SPEC §6) to members
  who RSVP'd yes or maybe. If the event moved since scheduling, the job
  reschedules itself for the new time instead of sending.
  """

  use Oban.Worker, queue: :mailers, max_attempts: 3

  import Ecto.Query, only: [from: 2]

  alias Kammer.Events.Event
  alias Kammer.Events.EventRsvp
  alias Kammer.Repo

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()}
  def perform(%Oban.Job{args: %{"event_id" => event_id, "starts_at" => scheduled_starts_at}}) do
    case Repo.get(Event, event_id) do
      nil ->
        :ok

      %Event{} = event ->
        group = Repo.get!(Kammer.Groups.Group, event.group_id)

        cond do
          event.cancelled_at ->
            # Cancelled since scheduling (a series occurrence, SPEC
            # §6's "cancel one date") — nothing to remind about.
            :ok

          not Kammer.Groups.Group.feature_enabled?(group, :events) ->
            # Feature toggled off since scheduling (ADR 0016): a hidden
            # feature must not keep emailing people.
            :ok

          DateTime.to_iso8601(event.starts_at) == scheduled_starts_at ->
            send_reminders(event)

          true ->
            reschedule(event)
        end
    end
  end

  defp send_reminders(event) do
    attendees =
      Repo.all(
        from(rsvp in EventRsvp,
          where: rsvp.event_id == ^event.id and rsvp.status in [:yes, :maybe],
          join: user in assoc(rsvp, :user),
          select: user
        )
      )

    group = Repo.get!(Kammer.Groups.Group, event.group_id)

    Enum.each(attendees, fn user ->
      level = Kammer.Notifications.effective_level(user, group)
      channels = Kammer.Notifications.channels_for(:event_reminder, level)

      if :email in channels do
        Kammer.Events.EventNotifier.deliver_reminder(user, event)
      end

      if :in_app in channels do
        Kammer.Notifications.insert_notification!(%{
          user_id: user.id,
          community_id: event.community_id,
          group_id: event.group_id,
          kind: :event_reminder,
          event_id: event.id
        })
      end

      if :push in channels do
        Kammer.Notifications.send_push(user, %{
          title: event.title,
          body: Calendar.strftime(event.starts_at, "%Y-%m-%d %H:%M UTC"),
          url: KammerWeb.Endpoint.url()
        })
      end
    end)

    :ok
  end

  defp reschedule(event) do
    reminder_at = DateTime.add(event.starts_at, -24, :hour)

    if DateTime.compare(reminder_at, DateTime.utc_now()) == :gt do
      %{"event_id" => event.id, "starts_at" => DateTime.to_iso8601(event.starts_at)}
      |> __MODULE__.new(scheduled_at: reminder_at)
      |> Oban.insert()
    end

    :ok
  end
end
