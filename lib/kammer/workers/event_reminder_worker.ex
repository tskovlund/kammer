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
        if DateTime.to_iso8601(event.starts_at) == scheduled_starts_at do
          send_reminders(event)
        else
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

    Enum.each(attendees, fn user ->
      Kammer.Events.EventNotifier.deliver_reminder(user, event)
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
