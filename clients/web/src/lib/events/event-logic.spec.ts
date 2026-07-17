import { describe, expect, it } from 'vitest';
import {
	applyRsvp,
	claimedByMe,
	rsvpNeedsRefetch,
	slotHasRoom,
	upsertComment
} from './event-logic.js';
import type { Comment, Event } from './types.js';

function baseEvent(overrides: Partial<Event> = {}): Event {
	return {
		id: 'e1',
		group_id: 'g1',
		group: { id: 'g1', name: 'G', slug: 'g' },
		series_id: null,
		title: 'E',
		description_markdown: null,
		starts_at: '2026-06-10T10:00:00Z',
		ends_at: null,
		all_day: false,
		timezone: 'Etc/UTC',
		location_name: null,
		location_url: null,
		cancelled: false,
		comments_locked: false,
		capacity: null,
		rsvp_counts: { yes: 0, maybe: 0, no: 0, waitlisted: 0 },
		my_rsvp: null,
		waitlist_position: null,
		waitlist: [],
		slots: [],
		comments: [],
		...overrides
	};
}

function comment(id: string, overrides: Partial<Comment> = {}): Comment {
	return {
		id,
		parent_comment_id: null,
		author: { type: 'user', id: 'u1', display_name: 'A' },
		body_markdown: 'hi',
		deleted: false,
		pending_approval: false,
		inserted_at: '2026-06-01T00:00:00Z',
		edited_at: null,
		reactions: {},
		my_reactions: [],
		...overrides
	};
}

describe('applyRsvp', () => {
	it('adds a first answer and bumps that count', () => {
		const next = applyRsvp(baseEvent(), 'yes');
		expect(next.my_rsvp).toBe('yes');
		expect(next.rsvp_counts).toEqual({ yes: 1, maybe: 0, no: 0, waitlisted: 0 });
	});

	it('moves the answer, shifting counts both ways', () => {
		const event = baseEvent({
			my_rsvp: 'yes',
			rsvp_counts: { yes: 3, maybe: 1, no: 0, waitlisted: 0 }
		});
		const next = applyRsvp(event, 'maybe');
		expect(next.my_rsvp).toBe('maybe');
		expect(next.rsvp_counts).toEqual({ yes: 2, maybe: 2, no: 0, waitlisted: 0 });
	});

	it('never pretends a waitlisted viewer got seated, but lets them leave the queue', () => {
		// A yes while waitlisted keeps the queue spot server-side (issue
		// #318), so optimism must not fake a seat…
		const queued = baseEvent({
			capacity: 1,
			my_rsvp: 'waitlisted',
			waitlist_position: 2,
			rsvp_counts: { yes: 1, maybe: 0, no: 0, waitlisted: 2 }
		});
		expect(applyRsvp(queued, 'yes')).toBe(queued);

		// …while declining really does leave the waitlist.
		const declined = applyRsvp(queued, 'no');
		expect(declined.my_rsvp).toBe('no');
		expect(declined.waitlist_position).toBeNull();
		expect(declined.rsvp_counts).toEqual({ yes: 1, maybe: 0, no: 1, waitlisted: 1 });
	});

	it('is a no-op when re-selecting the same answer', () => {
		const event = baseEvent({
			my_rsvp: 'no',
			rsvp_counts: { yes: 0, maybe: 0, no: 1, waitlisted: 0 }
		});
		expect(applyRsvp(event, 'no')).toBe(event);
	});

	it('never drives a count below zero', () => {
		const event = baseEvent({
			my_rsvp: 'yes',
			rsvp_counts: { yes: 0, maybe: 0, no: 0, waitlisted: 0 }
		});
		const next = applyRsvp(event, 'no');
		expect(next.rsvp_counts.yes).toBe(0);
		expect(next.rsvp_counts.no).toBe(1);
	});
});

describe('rsvpNeedsRefetch', () => {
	it('refetches any yes→away on a capped event, even when the snapshot shows no queue', () => {
		// The snapshot may be stale — a queue can have formed (or a cap been
		// added in another tab) since load — so a freed seat's effects are
		// re-read from the server, never inferred from local counts.
		const counts = { yes: 2, maybe: 0, no: 0, waitlisted: 0 };
		const capped = baseEvent({ capacity: 2, my_rsvp: 'yes', rsvp_counts: counts });
		expect(rsvpNeedsRefetch(capped, 'no', 'no')).toBe(true);

		// Uncapped, a freed seat promotes nobody: the optimistic patch stands.
		const uncapped = baseEvent({ my_rsvp: 'yes', rsvp_counts: counts });
		expect(rsvpNeedsRefetch(uncapped, 'no', 'no')).toBe(false);
	});
});

describe('upsertComment', () => {
	it('appends a new comment', () => {
		const event = baseEvent({ comments: [comment('a')] });
		const next = upsertComment(event, comment('b'));
		expect(next.comments.map((c) => c.id)).toEqual(['a', 'b']);
	});

	it('replaces an existing comment by id, preserving order', () => {
		const event = baseEvent({ comments: [comment('a'), comment('b')] });
		const next = upsertComment(event, comment('a', { body_markdown: 'edited', edited_at: 'x' }));
		expect(next.comments.map((c) => c.id)).toEqual(['a', 'b']);
		expect(next.comments[0].body_markdown).toBe('edited');
	});
});

describe('slot helpers', () => {
	const slot = {
		id: 's1',
		title: 'Cake',
		capacity: 2,
		taken: 1,
		claimants: [{ type: 'user' as const, id: 'u1', display_name: 'A' }]
	};

	it('claimedByMe matches the viewer among claimants', () => {
		expect(claimedByMe(slot, 'u1')).toBe(true);
		expect(claimedByMe(slot, 'u2')).toBe(false);
	});

	it('slotHasRoom is false only at capacity', () => {
		expect(slotHasRoom(slot)).toBe(true);
		expect(slotHasRoom({ ...slot, taken: 2 })).toBe(false);
	});
});
