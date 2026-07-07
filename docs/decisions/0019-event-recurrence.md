# ADR 0019: Recurring events materialize as ordinary Event rows

## Context

SPEC §6: "Recurrence: weekly / biweekly / monthly series (constrained
RRULE; no freeform editor), per-instance overrides (cancel/move one
date), per-instance RSVP, and an organizer attendance matrix (members
× upcoming instances)." Events already carry RSVPs, signup slots, the
shared comment engine, email reminders, and ICS feeds — all keyed on
a single `Event` row.

## Decision

**No separate occurrence table.** A recurring series is one
`EventSeries` row (just the rule: frequency, `until`) plus one
materialized `Event` row per occurrence, linked by `series_id`.
Every occurrence is a completely ordinary event: RSVPs, slots,
comments, ICS feed inclusion, and reminder scheduling all run through
the exact same code a standalone event already uses, unmodified.

**"Cancel one date"** is a nullable `cancelled_at` on `Event` — the
row (and its RSVP/comment history) stays; it's excluded from
listings, reminders, and ICS feeds, but still viewable directly with
a banner. **"Move one date"** needs no new code at all: it's just
`update_event/3` on that occurrence's `starts_at`/`ends_at`, since an
occurrence is a real, independently-editable event row.

**"Constrained RRULE"** (`Kammer.Events.Recurrence`) is pure date
math, not an RRULE parser/library: weekly, biweekly, or monthly
(day-of-month preserved, clamped for short months, computed from the
_original_ date each time so a "the 31st" series snaps back after a
28-day February instead of drifting permanently down), bounded by a
required `until` date and a hard cap of 52 occurrences. Arithmetic
happens in the series' timezone so wall-clock time survives DST.

**The attendance matrix** is computed from existing data — group
membership rows × each occurrence's already-loaded RSVPs — gated to
whoever manages the series (its creator or a group moderator), not
exposed to plain members.

## Consequences

- Zero schema or code changes to `EventRsvp`, `EventSlot`,
  `SlotClaim`, comments, guest RSVP tokens, `Kammer.Calendar.ICS`, or
  `EventReminderWorker` beyond a `cancelled_at` skip check — the
  entire existing single-event surface area keeps working unchanged.
- ICS feeds show N separate `VEVENT`s per series rather than one
  RFC 5545 `RRULE` block; calendar apps see distinct events, not a
  recognized recurring series. Acceptable for "lite" — revisit only if
  users ask for native recurring-event grouping in their calendar app.
- Series creation is eager and bounded (materializes every occurrence
  up front, capped at 52) rather than a rolling window — no background
  job to keep a series "topped up," at the cost of a hard ceiling on
  how far out a series can run.
- Deleting a whole series isn't a built-in action (only per-occurrence
  cancel) — SPEC only asks for cancelling/moving individual dates.
