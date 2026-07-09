import type { Comment, Event, RsvpStatus } from './types.js';

/**
 * Apply an RSVP change to an event locally, for an optimistic update: move
 * the viewer's answer to `next` and shift the counts by one (removing the
 * previous answer's tally if there was one). Re-selecting the same answer is
 * a no-op. The server is authoritative; this only makes the tap feel instant
 * until the response confirms it.
 */
export function applyRsvp(event: Event, next: RsvpStatus): Event {
	const previous = event.my_rsvp;
	if (previous === next) return event;

	const counts = { ...event.rsvp_counts };
	if (previous) counts[previous] = Math.max(0, counts[previous] - 1);
	counts[next] = (counts[next] ?? 0) + 1;

	return { ...event, my_rsvp: next, rsvp_counts: counts };
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
