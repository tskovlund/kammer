import type { Comment, Event, RsvpStatus } from './types.js';

/**
 * Whether an RSVP write must refetch the event rather than trust the
 * optimistic patch, which only ever moves the caller's own row (issue
 * #318). Three paths leave the rendered event stale without a refetch:
 * - the server resolved the request to a different status (a yes past
 *   the cap came back `waitlisted`);
 * - the caller was waitlisted before the tap: a re-yes can come back
 *   `yes` (the server's self-heal promoted them, same outcome as
 *   requested), and leaving the queue renumbers everyone behind them;
 * - the caller was seated on a capped event and moved away: the freed
 *   seat can promote the queue head — rows the patch never touches —
 *   and the snapshot can't be trusted to know whether a queue even
 *   exists (one may have formed since load), so any yes→away on a
 *   capped event refetches rather than inferring from stale counts.
 */
export function rsvpNeedsRefetch(
	previous: Event,
	requested: RsvpStatus,
	outcome: Event['my_rsvp']
): boolean {
	return (
		outcome !== requested ||
		previous.my_rsvp === 'waitlisted' ||
		(previous.my_rsvp === 'yes' && previous.capacity != null)
	);
}

/**
 * Apply an RSVP change to an event locally, for an optimistic update: move
 * the viewer's answer to `next` and shift the counts by one (removing the
 * previous answer's tally if there was one). Re-selecting the same answer is
 * a no-op — and so is a `yes` while waitlisted (issue #318): the server
 * keeps the queue spot, so pretending to be seated would just snap back.
 * The server is authoritative; this only makes the tap feel instant until
 * the response confirms it.
 */
export function applyRsvp(event: Event, next: RsvpStatus): Event {
	const previous = event.my_rsvp;
	if (previous === next) return event;
	if (previous === 'waitlisted' && next === 'yes') return event;

	const counts = { ...event.rsvp_counts };
	if (previous) counts[previous] = Math.max(0, counts[previous] - 1);
	counts[next] = (counts[next] ?? 0) + 1;

	const waitlistPosition = previous === 'waitlisted' ? null : event.waitlist_position;
	return { ...event, my_rsvp: next, rsvp_counts: counts, waitlist_position: waitlistPosition };
}

/** Insert a new comment, or replace an existing one by id (edit/delete/react). */
export function upsertComment(event: Event, comment: Comment): Event {
	const exists = event.comments.some((existing) => existing.id === comment.id);
	const comments = exists
		? event.comments.map((existing) => (existing.id === comment.id ? comment : existing))
		: [...event.comments, comment];
	return { ...event, comments };
}

/** Whether the viewer holds a claim on a slot (their user id among claimants). */
export function claimedByMe(slot: Event['slots'][number], userId: string): boolean {
	return (
		slot.claimants?.some((claimant) => claimant?.type === 'user' && claimant.id === userId) ?? false
	);
}

/** Whether a slot still has room for another claim. */
export function slotHasRoom(slot: Event['slots'][number]): boolean {
	return slot.taken < slot.capacity;
}
