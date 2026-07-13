import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from '$lib/feed/api.js';
import type { Instance } from '$lib/instances/types.js';
import type { Event, RsvpStatus } from './types.js';

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
		rsvp_counts: { yes: 0, maybe: 0, no: 0 },
		my_rsvp: null,
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
			event({ my_rsvp: 'no', rsvp_counts: { yes: 2, maybe: 0, no: 1 } })
		);

		let midFlight: RsvpStatus | null | undefined;
		vi.mocked(api.rsvp).mockImplementation(async () => {
			midFlight = store.event?.my_rsvp;
			throw new ApiError('server', 'nope', 500);
		});

		await store.rsvp('yes');

		// The tap was reflected instantly (visible while the request was in flight)…
		expect(midFlight).toBe('yes');
		// …then rolled back to the pre-tap answer and counts, with the failure surfaced.
		expect(store.event?.my_rsvp).toBe('no');
		expect(store.event?.rsvp_counts).toEqual({ yes: 2, maybe: 0, no: 1 });
		expect(store.actionError).toBe('server');
	});

	it('keeps the optimistic RSVP once the server accepts it — no refetch, no rollback', async () => {
		const store = await readyStore(event());
		vi.mocked(api.rsvp).mockResolvedValue(undefined);

		await store.rsvp('yes');

		expect(store.event?.my_rsvp).toBe('yes');
		expect(store.event?.rsvp_counts).toEqual({ yes: 1, maybe: 0, no: 0 });
		expect(store.actionError).toBeNull();
	});
});
