defmodule Kammer.EventsTest do
  use Kammer.DataCase, async: true
  use Oban.Testing, repo: Kammer.Repo

  import Kammer.CommunitiesFixtures

  alias Kammer.Calendar.ICS
  alias Kammer.Events
  alias Kammer.Events.EventRsvp
  alias Kammer.Workers.NotificationFanoutWorker

  defp event_context do
    {community, _owner} = community_with_owner_fixture()
    group = group_fixture(community)
    group_owner = group_member_fixture(group, :owner)
    member = group_member_fixture(group)
    %{community: community, group: group, group_owner: group_owner, member: member}
  end

  defp future(hours), do: DateTime.add(DateTime.utc_now(:second), hours, :hour)

  defp promotion_args(event, user) do
    %{"type" => "event_promotion", "event_id" => event.id, "user_id" => user.id}
  end

  defp drain_delivered_emails do
    receive do
      {:email, _email} -> drain_delivered_emails()
    after
      0 -> :ok
    end
  end

  defp delivered_emails(acc \\ []) do
    receive do
      {:email, email} -> delivered_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "create_event/3" do
    setup do
      event_context()
    end

    test "members create events; posting policy applies", %{
      community: community,
      group: group,
      member: member
    } do
      assert {:ok, event} =
               Events.create_event(member, group, %{
                 "title" => "Rehearsal",
                 "starts_at" => future(48),
                 "timezone" => "Europe/Copenhagen"
               })

      assert event.community_id == community.id

      announcement_group = group_fixture(community, posting_policy: :admins_only)
      announcement_member = group_member_fixture(announcement_group)

      assert {:error, :unauthorized} =
               Events.create_event(announcement_member, announcement_group, %{
                 "title" => "Nope",
                 "starts_at" => future(48)
               })
    end

    test "rejects end before start", %{group: group, member: member} do
      assert {:error, changeset} =
               Events.create_event(member, group, %{
                 "title" => "Backwards",
                 "starts_at" => future(48),
                 "ends_at" => future(24)
               })

      assert changeset.errors[:ends_at]
    end

    test "rejects a javascript: location_url (issue #247 — scheme rules themselves are covered by Kammer.ValidationTest)",
         %{group: group, member: member} do
      assert {:error, changeset} =
               Events.create_event(member, group, %{
                 "title" => "Bad location",
                 "starts_at" => future(48),
                 "location_url" => "javascript:alert(1)"
               })

      assert changeset.errors[:location_url]
    end

    test "schedules a reminder job for events more than a day out", %{
      group: group,
      member: member
    } do
      {:ok, event} =
        Events.create_event(member, group, %{"title" => "Later", "starts_at" => future(72)})

      assert_enqueued(
        worker: Kammer.Workers.EventReminderWorker,
        args: %{"event_id" => event.id}
      )
    end
  end

  describe "visibility and listing" do
    setup do
      event_context()
    end

    test "events follow group visibility", %{community: community, member: member} do
      private_group = group_fixture(community, visibility: :private)
      private_member = group_member_fixture(private_group)

      {:ok, private_event} =
        Events.create_event(private_member, private_group, %{
          "title" => "Secret Session",
          "starts_at" => future(48)
        })

      # A community member outside the private group can't fetch or list it.
      assert {:error, :unauthorized} =
               Events.fetch_viewable_event(member, community, private_event.id)

      upcoming_titles = Events.list_upcoming_events(member, community) |> Enum.map(& &1.title)
      refute "Secret Session" in upcoming_titles

      insider_titles =
        Events.list_upcoming_events(private_member, community) |> Enum.map(& &1.title)

      assert "Secret Session" in insider_titles
    end

    test "past and upcoming are separated", %{community: community, group: group, member: member} do
      {:ok, _upcoming} =
        Events.create_event(member, group, %{"title" => "Soon", "starts_at" => future(24)})

      {:ok, past_event} =
        Events.create_event(member, group, %{"title" => "Yesterday", "starts_at" => future(30)})

      past_event
      |> Ecto.Changeset.change(starts_at: DateTime.add(DateTime.utc_now(:second), -1, :day))
      |> Kammer.Repo.update!()

      assert Events.list_upcoming_events(member, community) |> Enum.map(& &1.title) == ["Soon"]
      assert Events.list_past_events(member, community) |> Enum.map(& &1.title) == ["Yesterday"]
    end
  end

  describe "rsvp/3" do
    setup do
      context = event_context()

      {:ok, event} =
        Events.create_event(context.member, context.group, %{
          "title" => "Concert",
          "starts_at" => future(48)
        })

      Map.put(context, :event, event)
    end

    test "members RSVP and can change their answer", %{event: event, member: member} do
      assert {:ok, rsvp} = Events.rsvp(member, event, :yes)
      assert rsvp.status == :yes

      assert {:ok, changed} = Events.rsvp(member, event, :maybe)
      assert changed.status == :maybe
      assert Events.get_rsvp(event, member).status == :maybe
    end

    test "non-members cannot RSVP", %{community: community, event: event} do
      outsider = member_fixture(community)
      assert {:error, :unauthorized} = Events.rsvp(outsider, event, :yes)
    end
  end

  describe "comments (same engine)" do
    setup do
      context = event_context()

      {:ok, event} =
        Events.create_event(context.member, context.group, %{
          "title" => "Party",
          "starts_at" => future(48)
        })

      Map.put(context, :event, event)
    end

    test "members comment with one reply level", %{event: event, member: member} do
      {:ok, comment} = Events.create_comment(member, event, %{"body_markdown" => "Bring cake"})

      {:ok, reply} =
        Events.create_comment(member, event, %{
          "body_markdown" => "And coffee",
          "parent_comment_id" => comment.id
        })

      {:ok, deep_reply} =
        Events.create_comment(member, event, %{
          "body_markdown" => "reparented",
          "parent_comment_id" => reply.id
        })

      assert deep_reply.parent_comment_id == comment.id
    end

    test "comment policy off blocks event comments", %{community: community} do
      quiet_group = group_fixture(community, comment_policy: :off)
      quiet_member = group_member_fixture(quiet_group)

      {:ok, event} =
        Events.create_event(quiet_member, quiet_group, %{
          "title" => "Silent",
          "starts_at" => future(48)
        })

      assert {:error, :unauthorized} =
               Events.create_comment(quiet_member, event, %{"body_markdown" => "hi"})
    end

    test "commenting is rate limited per author", %{event: event, member: member} do
      for i <- 1..20 do
        assert {:ok, _comment} =
                 Events.create_comment(member, event, %{"body_markdown" => "Comment #{i}"})
      end

      assert {:error, :rate_limited} =
               Events.create_comment(member, event, %{"body_markdown" => "One too many"})
    end
  end

  describe "management" do
    setup do
      event_context()
    end

    test "creator and moderators manage; others don't", %{
      group: group,
      group_owner: group_owner,
      member: member
    } do
      {:ok, event} =
        Events.create_event(member, group, %{"title" => "Mine", "starts_at" => future(48)})

      other_member = group_member_fixture(group)

      assert {:error, :unauthorized} =
               Events.update_event(other_member, event, %{"title" => "Hijack"})

      assert {:ok, updated} = Events.update_event(member, event, %{"title" => "Mine (edited)"})
      assert updated.title == "Mine (edited)"

      assert {:ok, _deleted} = Events.delete_event(group_owner, updated)
    end
  end

  describe "capacity and waitlist (issue #318)" do
    setup do
      context = event_context()

      {:ok, event} =
        Events.create_event(context.member, context.group, %{
          "title" => "Capped",
          "starts_at" => future(48),
          "capacity" => 1
        })

      Map.put(context, :event, event)
    end

    test "the cap admits until full, then waitlists in arrival order; re-yes keeps the spot", %{
      group: group,
      event: event,
      member: attendee
    } do
      first_in_line = group_member_fixture(group)
      second_in_line = group_member_fixture(group)

      assert {:ok, %EventRsvp{status: :yes, waitlisted_at: nil}} =
               Events.rsvp(attendee, event, :yes)

      assert {:ok, %EventRsvp{status: :waitlisted} = queued} =
               Events.rsvp(first_in_line, event, :yes)

      assert queued.waitlisted_at
      assert {:ok, %EventRsvp{status: :waitlisted}} = Events.rsvp(second_in_line, event, :yes)

      # Asking again neither seats them nor resets their queue spot.
      assert {:ok, %EventRsvp{status: :waitlisted, waitlisted_at: kept_at}} =
               Events.rsvp(first_in_line, event, :yes)

      assert kept_at == queued.waitlisted_at
    end

    test "cancelling frees the seat for the first in line, who is notified at their level", %{
      group: group,
      event: event,
      member: attendee
    } do
      first_in_line = group_member_fixture(group)
      second_in_line = group_member_fixture(group)
      {:ok, _seated} = Events.rsvp(attendee, event, :yes)
      {:ok, _queued} = Events.rsvp(first_in_line, event, :yes)
      {:ok, _queued} = Events.rsvp(second_in_line, event, :yes)

      assert {:ok, %EventRsvp{status: :no}} = Events.rsvp(attendee, event, :no)

      assert Events.get_rsvp(event, first_in_line).status == :yes
      assert Events.get_rsvp(event, second_in_line).status == :waitlisted

      assert_enqueued(
        worker: NotificationFanoutWorker,
        args: promotion_args(event, first_in_line)
      )

      refute_enqueued(
        worker: NotificationFanoutWorker,
        args: promotion_args(event, second_in_line)
      )

      drain_delivered_emails()
      assert :ok = perform_job(NotificationFanoutWorker, promotion_args(event, first_in_line))

      assert Repo.get_by(Kammer.Notifications.Notification,
               user_id: first_in_line.id,
               event_id: event.id,
               kind: :event_promoted
             )

      assert [email] = delivered_emails()
      assert Enum.any?(email.to, fn {_name, address} -> address == first_in_line.email end)
      assert email.subject =~ "you're attending Capped"
    end

    test "a waitlisted decline leaves the queue without promoting anyone", %{
      group: group,
      event: event,
      member: attendee
    } do
      first_in_line = group_member_fixture(group)
      second_in_line = group_member_fixture(group)
      {:ok, _seated} = Events.rsvp(attendee, event, :yes)
      {:ok, _queued} = Events.rsvp(first_in_line, event, :yes)
      {:ok, _queued} = Events.rsvp(second_in_line, event, :yes)

      assert {:ok, %EventRsvp{status: :no}} = Events.rsvp(first_in_line, event, :no)
      assert Events.get_rsvp(event, attendee).status == :yes
      refute_enqueued(worker: NotificationFanoutWorker, args: %{"type" => "event_promotion"})

      # The queue shifted: the next freed seat goes to the remaining waiter.
      {:ok, _cancelled} = Events.rsvp(attendee, event, :no)
      assert Events.get_rsvp(event, second_in_line).status == :yes
    end

    test "raising the cap promotes as many as fit in order; lowering demotes nobody", %{
      group: group,
      event: event,
      member: creator
    } do
      [first_in_line, second_in_line, third_in_line] =
        for _n <- 1..3, do: group_member_fixture(group)

      {:ok, _seated} = Events.rsvp(creator, event, :yes)
      {:ok, _queued} = Events.rsvp(first_in_line, event, :yes)
      {:ok, _queued} = Events.rsvp(second_in_line, event, :yes)
      {:ok, _queued} = Events.rsvp(third_in_line, event, :yes)

      assert {:ok, raised} = Events.update_event(creator, event, %{"capacity" => 3})

      assert Events.get_rsvp(event, first_in_line).status == :yes
      assert Events.get_rsvp(event, second_in_line).status == :yes
      assert Events.get_rsvp(event, third_in_line).status == :waitlisted

      assert_enqueued(
        worker: NotificationFanoutWorker,
        args: promotion_args(event, first_in_line)
      )

      assert_enqueued(
        worker: NotificationFanoutWorker,
        args: promotion_args(event, second_in_line)
      )

      # Removing the cap seats everyone still queued.
      assert {:ok, unlimited} = Events.update_event(creator, raised, %{"capacity" => nil})
      assert unlimited.capacity == nil
      assert Events.get_rsvp(event, third_in_line).status == :yes

      # Lowering below the seated count demotes nobody, and blocks
      # promotion until attrition catches up: a cancel at 4/1 seats no one.
      assert {:ok, _lowered} = Events.update_event(creator, unlimited, %{"capacity" => 1})
      assert Events.get_rsvp(event, second_in_line).status == :yes
      late = group_member_fixture(group)
      assert {:ok, %EventRsvp{status: :waitlisted}} = Events.rsvp(late, event, :yes)
      assert {:ok, _freed} = Events.rsvp(first_in_line, event, :no)
      assert Events.get_rsvp(event, late).status == :waitlisted
    end

    # The sandbox hands every allowed Task the parent's single
    # connection, so these racing writers physically run one at a time —
    # the FOR UPDATE lock in `write_rsvp` is never actually contended
    # here (deleting it wouldn't fail this test). What it pins is the
    # funnel itself: each writer re-reads the seat count inside its own
    # transaction, so racing writers applied in sequence yield exactly
    # one seat and three queue spots, whatever the arrival order.
    test "racing yes RSVPs funnel through the transaction sequentially — one seat, three queued",
         %{group: group, event: event} do
      contenders = for _n <- 1..4, do: group_member_fixture(group)
      parent = self()

      statuses =
        contenders
        |> Enum.map(fn user ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            {:ok, rsvp} = Events.rsvp(user, event, :yes)
            rsvp.status
          end)
        end)
        |> Task.await_many(:infinity)

      assert Enum.count(statuses, &(&1 == :yes)) == 1
      assert Enum.count(statuses, &(&1 == :waitlisted)) == 3
    end

    # Same sandbox caveat as above: the two cancels share one connection
    # and run sequentially, so the lock is uncontended — this pins that
    # cancels applied back-to-back promote the lone waiter exactly once
    # (the second freed seat finds an empty queue, not a re-promotion).
    test "racing cancels applied sequentially promote the lone waiter exactly once", %{
      group: group,
      member: creator
    } do
      {:ok, event} =
        Events.create_event(creator, group, %{
          "title" => "Double cancel",
          "starts_at" => future(48),
          "capacity" => 2
        })

      [seated_one, seated_two] = for _n <- 1..2, do: group_member_fixture(group)
      waiter = group_member_fixture(group)
      {:ok, _seated} = Events.rsvp(seated_one, event, :yes)
      {:ok, _seated} = Events.rsvp(seated_two, event, :yes)
      {:ok, _queued} = Events.rsvp(waiter, event, :yes)

      parent = self()

      [seated_one, seated_two]
      |> Enum.map(fn user ->
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          Events.rsvp(user, event, :no)
        end)
      end)
      |> Task.await_many(:infinity)

      assert Events.get_rsvp(event, waiter).status == :yes

      promotion_jobs =
        all_enqueued(worker: NotificationFanoutWorker)
        |> Enum.filter(&(&1.args["type"] == "event_promotion"))

      assert [job] = promotion_jobs
      assert job.args["user_id"] == waiter.id
    end

    test "a seat freed out-of-band never lets a new yes jump the queue", %{
      group: group,
      member: creator
    } do
      {:ok, event} =
        Events.create_event(creator, group, %{
          "title" => "Self-heal",
          "starts_at" => future(48),
          "capacity" => 2
        })

      [seated, waiter, newcomer] = for _n <- 1..3, do: group_member_fixture(group)
      {:ok, _seated} = Events.rsvp(creator, event, :yes)
      {:ok, _seated} = Events.rsvp(seated, event, :yes)
      {:ok, _queued} = Events.rsvp(waiter, event, :yes)

      # A cascade-style erasure (e.g. account deletion) removes a seated
      # RSVP without running the promotion pass — the freed seat is stale.
      Repo.delete_all(
        from(rsvp in EventRsvp, where: rsvp.event_id == ^event.id and rsvp.user_id == ^seated.id)
      )

      # The next yes must not grab that stale seat past a non-empty
      # queue: it queues, and the same write's promotion pass seats the
      # earlier waiter — the advertised no-jump reconciliation invariant.
      assert {:ok, %EventRsvp{status: :waitlisted}} = Events.rsvp(newcomer, event, :yes)
      assert Events.get_rsvp(event, waiter).status == :yes
    end

    test "a promotion job delivers nothing when the promoted RSVP flipped back before it ran", %{
      group: group,
      event: event,
      member: attendee
    } do
      waiter = group_member_fixture(group)
      {:ok, _seated} = Events.rsvp(attendee, event, :yes)
      {:ok, _queued} = Events.rsvp(waiter, event, :yes)
      {:ok, _freed} = Events.rsvp(attendee, event, :no)

      assert_enqueued(worker: NotificationFanoutWorker, args: promotion_args(event, waiter))

      # The seat came and went before the job ran: the worker's re-check
      # sees the RSVP no longer stands as attending and delivers nothing.
      assert {:ok, %EventRsvp{status: :no}} = Events.rsvp(waiter, event, :no)

      drain_delivered_emails()
      assert :ok = perform_job(NotificationFanoutWorker, promotion_args(event, waiter))

      refute Repo.get_by(Kammer.Notifications.Notification,
               user_id: waiter.id,
               event_id: event.id
             )

      assert delivered_emails() == []
    end

    test "a promotion job never notifies someone removed from the group after waitlisting", %{
      group: group,
      group_owner: group_owner,
      event: event,
      member: attendee
    } do
      waiter = group_member_fixture(group)
      {:ok, _seated} = Events.rsvp(attendee, event, :yes)
      {:ok, _queued} = Events.rsvp(waiter, event, :yes)

      # Removal doesn't erase RSVPs, so the queue entry survives and the
      # freed seat still promotes it — but the worker must not deliver to
      # an ex-member (effective_level would fall back to the group
      # default and leak the event title in-app, by push, and by email).
      membership = Kammer.Groups.get_membership(group, waiter)
      {:ok, _removed} = Kammer.Groups.remove_member(group_owner, group, membership)

      {:ok, _freed} = Events.rsvp(attendee, event, :no)
      assert Events.get_rsvp(event, waiter).status == :yes
      assert_enqueued(worker: NotificationFanoutWorker, args: promotion_args(event, waiter))

      drain_delivered_emails()
      assert :ok = perform_job(NotificationFanoutWorker, promotion_args(event, waiter))

      refute Repo.get_by(Kammer.Notifications.Notification,
               user_id: waiter.id,
               event_id: event.id
             )

      assert delivered_emails() == []
    end
  end

  describe "ICS" do
    setup do
      event_context()
    end

    test "single event export has valid structure", %{group: group, member: member} do
      {:ok, event} =
        Events.create_event(member, group, %{
          "title" => "Åbning; med, komma",
          "starts_at" => ~U[2026-08-01 18:00:00Z],
          "ends_at" => ~U[2026-08-01 21:00:00Z],
          "location_name" => "Stakladen"
        })

      ics = ICS.single(event)

      assert ics =~ "BEGIN:VCALENDAR"
      assert ics =~ "BEGIN:VEVENT"
      assert ics =~ "DTSTART:20260801T180000Z"
      assert ics =~ "DTEND:20260801T210000Z"
      assert ics =~ "SUMMARY:Åbning\\; med\\, komma"
      assert ics =~ "LOCATION:Stakladen"
      assert ics =~ "END:VCALENDAR"
    end

    test "all-day events use VALUE=DATE", %{group: group, member: member} do
      {:ok, event} =
        Events.create_event(member, group, %{
          "title" => "Festival",
          "starts_at" => ~U[2026-08-01 00:00:00Z],
          "ends_at" => ~U[2026-08-03 00:00:00Z],
          "all_day" => true,
          "timezone" => "Europe/Copenhagen"
        })

      ics = ICS.single(event)
      assert ics =~ "DTSTART;VALUE=DATE:20260801"
      assert ics =~ "DTEND;VALUE=DATE:20260804"
    end

    test "group and user feed tokens", %{group: group, member: member} do
      {:ok, _event} =
        Events.create_event(member, group, %{"title" => "Feed me", "starts_at" => future(48)})

      group_token = Events.ensure_group_ics_token(Kammer.Repo.reload!(group))
      assert {_group, [event]} = Events.events_for_group_token(group_token)
      assert event.title == "Feed me"

      user_token = Events.ensure_user_ics_token(member)
      assert {_user, user_events} = Events.events_for_user_token(user_token)
      assert Enum.any?(user_events, fn user_event -> user_event.title == "Feed me" end)

      # Another community's events don't leak into the user feed.
      {other_community, _other_owner} = community_with_owner_fixture()
      other_group = group_fixture(other_community)
      other_member = group_member_fixture(other_group)

      {:ok, _other_event} =
        Events.create_event(other_member, other_group, %{
          "title" => "Elsewhere",
          "starts_at" => future(48)
        })

      {_user, user_events} = Events.events_for_user_token(user_token)
      refute Enum.any?(user_events, fn user_event -> user_event.title == "Elsewhere" end)

      assert Events.events_for_group_token("bogus") == nil
      assert Events.events_for_user_token("bogus") == nil
    end
  end

  describe "reminder worker" do
    setup do
      event_context()
    end

    test "sends to yes/maybe RSVPs with an ICS attachment", %{
      group: group,
      member: member,
      group_owner: group_owner
    } do
      {:ok, event} =
        Events.create_event(member, group, %{"title" => "Reminded", "starts_at" => future(48)})

      {:ok, _rsvp} = Events.rsvp(member, event, :yes)
      {:ok, _rsvp} = Events.rsvp(group_owner, event, :no)

      drain_delivered_emails()

      assert :ok =
               perform_job(Kammer.Workers.EventReminderWorker, %{
                 "event_id" => event.id,
                 "starts_at" => DateTime.to_iso8601(event.starts_at)
               })

      # Exactly one email: the yes-RSVP gets the reminder with the ICS
      # attachment, the no-RSVP owner gets nothing.
      assert [email] = delivered_emails()
      assert Enum.any?(email.to, fn {_name, address} -> address == member.email end)
      refute Enum.any?(email.to, fn {_name, address} -> address == group_owner.email end)
      assert email.subject =~ "Reminded"
      assert Enum.any?(email.attachments, fn attachment -> attachment.filename == "event.ics" end)
    end

    test "reschedules itself when the event moved", %{group: group, member: member} do
      {:ok, event} =
        Events.create_event(member, group, %{"title" => "Moved", "starts_at" => future(48)})

      {:ok, updated} = Events.update_event(member, event, %{"starts_at" => future(96)})
      drain_delivered_emails()

      assert :ok =
               perform_job(Kammer.Workers.EventReminderWorker, %{
                 "event_id" => event.id,
                 "starts_at" => DateTime.to_iso8601(event.starts_at)
               })

      # A fresh job was enqueued carrying the new start time, and no
      # reminder email went out for the stale one.
      new_starts_at = DateTime.to_iso8601(updated.starts_at)

      assert Enum.any?(
               all_enqueued(worker: Kammer.Workers.EventReminderWorker),
               fn job -> job.args["starts_at"] == new_starts_at end
             )

      assert delivered_emails() == []
    end
  end
end
