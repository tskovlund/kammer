import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from '$lib/feed/api.js';
import type { Instance } from '$lib/instances/types.js';
import type { Event } from './types.js';

vi.mock('./api.js', async (importActual) => {
	const actual = await importActual<typeof import('./api.js')>();
	return { ...actual, fetchEvent: vi.fn(), rsvp: vi.fn() };
});

import * as api from './api.js';
import { createEventStore } from './event-store.svelte.js';

function instance(): Instance {
	return {
		id: 'i1',
		baseUrl: 'https://kammer.example.com',
		instanceName: 'Example',
		deviceToken: 'token-1',
		user: { id: 'u1', email: 'a@example.com', displayName: 'Alice' },
		addedAt: '2026-01-01T00:00:00Z'
	};
}

function event(overrides: Partial<Event> = {}): Event {
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

async function readyStore(initial: Event) {
	vi.mocked(api.fetchEvent).mockResolvedValue(initial);
	const store = createEventStore(instance(), 'c', initial.id);
	await store.load();
	return store;
}

beforeEach(() => {
	vi.clearAllMocks();
});

describe('optimistic RSVP rollback', () => {
	// Events have no realtime channel, so unlike feed-store's conditional
	// rollback there is no concurrent echo to preserve: a failed RSVP restores
	// the pre-tap snapshot wholesale.
	it('applies the RSVP before the response and rolls back the snapshot on failure', async () => {
		const store = await readyStore(
			event({ my_rsvp: 'no', rsvp_counts: { yes: 2, maybe: 0, no: 1, waitlisted: 0 } })
		);

		let midFlight: Event['my_rsvp'] | undefined;
		vi.mocked(api.rsvp).mockImplementation(async () => {
			midFlight = store.event?.my_rsvp;
			throw new ApiError('server', 'nope', 500);
		});

		await store.rsvp('yes');

		// The tap was reflected instantly (visible while the request was in flight)…
		expect(midFlight).toBe('yes');
		// …then rolled back to the pre-tap answer and counts, with the failure surfaced.
		expect(store.event?.my_rsvp).toBe('no');
		expect(store.event?.rsvp_counts).toEqual({ yes: 2, maybe: 0, no: 1, waitlisted: 0 });
		expect(store.actionError).toBe('server');
	});

	it('keeps the optimistic RSVP once the server accepts it — no refetch, no rollback', async () => {
		const store = await readyStore(event());
		vi.mocked(api.rsvp).mockResolvedValue('yes');

		await store.rsvp('yes');

		expect(store.event?.my_rsvp).toBe('yes');
		expect(store.event?.rsvp_counts).toEqual({ yes: 1, maybe: 0, no: 0, waitlisted: 0 });
		expect(store.actionError).toBeNull();
		expect(api.fetchEvent).toHaveBeenCalledTimes(1); // only the initial load
	});

	it('refetches the server truth when a yes comes back waitlisted (issue #318)', async () => {
		// Optimism guessed a seat; the outcome disagreed, so the store pulls
		// the authoritative event — status, counts, and queue position.
		const store = await readyStore(
			event({ capacity: 1, rsvp_counts: { yes: 1, maybe: 0, no: 0, waitlisted: 0 } })
		);
		const serverTruth = event({
			capacity: 1,
			my_rsvp: 'waitlisted',
			waitlist_position: 1,
			rsvp_counts: { yes: 1, maybe: 0, no: 0, waitlisted: 1 }
		});
		vi.mocked(api.rsvp).mockResolvedValue('waitlisted');
		vi.mocked(api.fetchEvent).mockResolvedValue(serverTruth);

		await store.rsvp('yes');

		expect(store.event?.my_rsvp).toBe('waitlisted');
		expect(store.event?.waitlist_position).toBe(1);
		expect(store.event?.rsvp_counts).toEqual({ yes: 1, maybe: 0, no: 0, waitlisted: 1 });
	});

	it('refetches quietly when a waitlisted re-yes comes back promoted (outcome equals request)', async () => {
		// The server's self-heal can seat a waiter on their own re-tap: the
		// outcome ('yes') matches the request, but the pre-tap answer was
		// waitlisted — without a refetch the UI stays stuck in the queue.
		const store = await readyStore(
			event({
				capacity: 2,
				my_rsvp: 'waitlisted',
				waitlist_position: 1,
				rsvp_counts: { yes: 1, maybe: 0, no: 0, waitlisted: 1 }
			})
		);
		const serverTruth = event({
			capacity: 2,
			my_rsvp: 'yes',
			waitlist_position: null,
			rsvp_counts: { yes: 2, maybe: 0, no: 0, waitlisted: 0 }
		});
		vi.mocked(api.rsvp).mockResolvedValue('yes');
		let loadStateDuringRefetch: string | undefined;
		vi.mocked(api.fetchEvent).mockImplementation(async () => {
			loadStateDuringRefetch = store.loadState;
			return serverTruth;
		});

		await store.rsvp('yes');

		expect(api.fetchEvent).toHaveBeenCalledTimes(2); // initial load + quiet refresh
		expect(store.event?.my_rsvp).toBe('yes');
		expect(store.event?.waitlist_position).toBeNull();
		// Quiet means quiet: the refetch never flips the page back to its
		// loading skeleton (which would drop comment drafts).
		expect(loadStateDuringRefetch).toBe('ready');
	});

	it('refetches when leaving the queue, so the remaining positions renumber', async () => {
		const store = await readyStore(
			event({
				capacity: 1,
				my_rsvp: 'waitlisted',
				waitlist_position: 1,
				rsvp_counts: { yes: 1, maybe: 0, no: 0, waitlisted: 2 }
			})
		);
		const serverTruth = event({
			capacity: 1,
			my_rsvp: 'no',
			waitlist_position: null,
			rsvp_counts: { yes: 1, maybe: 0, no: 1, waitlisted: 1 }
		});
		vi.mocked(api.rsvp).mockResolvedValue('no');
		vi.mocked(api.fetchEvent).mockResolvedValue(serverTruth);

		await store.rsvp('no');

		expect(api.fetchEvent).toHaveBeenCalledTimes(2); // initial load + quiet refresh
		expect(store.event?.rsvp_counts).toEqual({ yes: 1, maybe: 0, no: 1, waitlisted: 1 });
	});
});
