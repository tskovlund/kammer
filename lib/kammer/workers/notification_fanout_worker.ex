defmodule Kammer.Workers.NotificationFanoutWorker do
  @moduledoc """
  Asynchronous notification fan-out (SPEC §9) so posting stays instant on
  a mid-range phone (SPEC §20): computes recipients and delivers in-app,
  email, and push per the level matrix.
  """

  use Oban.Worker, queue: :mailers, max_attempts: 3

  alias Kammer.Newsletters
  alias Kammer.Notifications
  alias Kammer.Repo

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: %{"type" => "post", "id" => post_id}}) do
    case Repo.get(Kammer.Feed.Post, post_id) do
      nil ->
        :ok

      post ->
        if not post.pending_approval do
          Notifications.fanout_post(post)
          Newsletters.notify_subscribers(post)
        end

        :ok
    end
  end

  def perform(%Oban.Job{args: %{"type" => "comment", "id" => comment_id}}) do
    case Repo.get(Kammer.Feed.Comment, comment_id) do
      nil -> :ok
      comment -> Notifications.fanout_comment(comment)
    end
  end

  def perform(%Oban.Job{args: %{"type" => "event", "id" => event_id}}) do
    case Repo.get(Kammer.Events.Event, event_id) do
      nil -> :ok
      event -> Notifications.fanout_event(event)
    end
  end

  # Waitlist promotions (issue #318): one job per promoted RSVP,
  # enqueued inside the promoting transaction. Delivery re-checks the
  # RSVP still stands as attending — a promoted attendee may have
  # cancelled again (or been erased) before the job ran — and that the
  # member is still in the host group: removal doesn't erase RSVPs, and
  # `Notifications.effective_level/2` falls back to the group default
  # for a non-member, so without this check a promotion would leak the
  # event title (in-app, push, and email) to someone already removed.
  def perform(%Oban.Job{
        args: %{"type" => "event_promotion", "event_id" => event_id, "user_id" => user_id}
      }) do
    with %Kammer.Events.Event{} = event <- Repo.get(Kammer.Events.Event, event_id),
         %Kammer.Accounts.User{} = user <- Repo.get(Kammer.Accounts.User, user_id),
         %Kammer.Events.EventRsvp{status: :yes} <-
           Repo.get_by(Kammer.Events.EventRsvp, event_id: event_id, user_id: user_id),
         %Kammer.Groups.GroupMembership{} <-
           Repo.get_by(Kammer.Groups.GroupMembership,
             group_id: event.group_id,
             user_id: user_id
           ) do
      Notifications.notify_waitlist_promotion(user, event)
    else
      _gone_or_changed -> :ok
    end
  end

  def perform(%Oban.Job{
        args: %{
          "type" => "event_promotion",
          "event_id" => event_id,
          "guest_identity_id" => guest_identity_id
        }
      }) do
    with %Kammer.Events.Event{} = event <- Repo.get(Kammer.Events.Event, event_id),
         %Kammer.Guests.GuestIdentity{} = identity <-
           Repo.get(Kammer.Guests.GuestIdentity, guest_identity_id),
         %Kammer.Events.EventRsvp{status: :yes} <-
           Repo.get_by(Kammer.Events.EventRsvp,
             event_id: event_id,
             guest_identity_id: guest_identity_id
           ) do
      Kammer.Guests.GuestNotifier.deliver_waitlist_promoted(identity, event)
      :ok
    else
      _gone_or_changed -> :ok
    end
  end
end
