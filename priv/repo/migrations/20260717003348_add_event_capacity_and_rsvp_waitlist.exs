defmodule Kammer.Repo.Migrations.AddEventCapacityAndRsvpWaitlist do
  use Ecto.Migration

  def change do
    alter table(:events) do
      # nil = unlimited (issue #318); a positive cap on attending RSVPs.
      add :capacity, :integer
    end

    create constraint(:events, :event_capacity_positive,
             check: "capacity IS NULL OR capacity > 0"
           )

    alter table(:event_rsvps) do
      # Set while an RSVP sits on the waitlist; microsecond precision plus
      # the id tiebreaker gives a deterministic, gap-tolerant queue order.
      add :waitlisted_at, :utc_datetime_usec
    end

    create index(:event_rsvps, [:event_id, :waitlisted_at],
             where: "status = 'waitlisted'",
             name: :event_rsvps_waitlist_order_index
           )
  end
end
