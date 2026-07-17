import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from '$lib/feed/api.js';
import type { Community } from '$lib/feed/types.js';
import type { Instance } from '$lib/instances/types.js';
import type { Event } from './types.js';

vi.mock('./api.js', async (importActual) => {
	const actual = await importActual<typeof import('./api.js')>();
	return { ...actual, fetchCommunities: vi.fn(), fetchCommunityEvents: vi.fn() };
});

import * as api from './api.js';
import { createEventsStore } from './events-store.svelte.js';

function instance(id: string, name: string): Instance {
	return {
		id,
		baseUrl: `https://${id}.example`,
		instanceName: name,
		deviceToken: 't',
		user: { id: `${id}-user`, email: 'a@a', displayName: 'A' },
		addedAt: '2026-01-01T00:00:00Z'
	};
}

function community(id: string, slug: string, name: string): Community {
	return {
		id,
		slug,
		name,
		description: null,
		accent_color: '#3E6B48',
		default_locale: 'en',
		listed_on_instance: false,
		require_real_names: false,
		viewer_can: []
	};
}

function event(id: string, startsAt: string, groupId = 'g'): Event {
	return {
		id,
		group_id: groupId,
		group: { id: groupId, name: 'Group', slug: 'group' },
		series_id: null,
		title: `Event ${id}`,
		description_markdown: null,
		starts_at: startsAt,
		ends_at: null,
		all_day: false,
		timezone: 'Etc/UTC',
		location_name: null,
		location_url: null,
		cancelled: false,
		comments_locked: false,
		rsvp_counts: { yes: 0, maybe: 0, no: 0, waitlisted: 0 },
		my_rsvp: null,
		waitlist: [],
		slots: [],
		comments: []
	};
}

const mockCommunities = vi.mocked(api.fetchCommunities);
const mockEvents = vi.mocked(api.fetchCommunityEvents);

describe('createEventsStore', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('merges events across instances and communities, soonest first', async () => {
		const a = instance('ia', 'Alpha');
		const b = instance('ib', 'Beta');
		mockCommunities.mockImplementation(async (inst) =>
			inst.id === 'ia'
				? [community('ca', 'ca', 'Choir'), community('cb', 'cb', 'Book club')]
				: [community('cc', 'cc', 'Cycling')]
		);
		mockEvents.mockImplementation(async (_inst, slug) => {
			if (slug === 'ca') return [event('a', '2026-06-12T10:00:00Z')];
			if (slug === 'cb') return [event('b', '2026-06-10T10:00:00Z')];
			return [event('c', '2026-06-11T10:00:00Z')];
		});

		const store = createEventsStore();
		await store.load([a, b]);

		// Flattened and sorted by start (earliest first).
		const allEvents = store.days.flatMap((day) => day.events.map((e) => e.id));
		expect(allEvents).toEqual(['b', 'c', 'a']);
		expect(store.failedInstances).toHaveLength(0);
		expect(store.loadState).toBe('ready');
		// Chips follow first sighting (soonest event) order.
		expect(store.chips.map((chip) => chip.name)).toEqual(['Book club', 'Cycling', 'Choir']);
	});

	it('surfaces a failing instance without blanking the rest', async () => {
		const ok = instance('ok', 'OK');
		const bad = instance('bad', 'Bad');
		mockCommunities.mockImplementation(async (inst) => {
			if (inst.id === 'bad') throw new ApiError('auth', 'signed out', 401);
			return [community('c1', 'c1', 'One')];
		});
		mockEvents.mockResolvedValue([event('x', '2026-06-10T10:00:00Z')]);

		const store = createEventsStore();
		await store.load([ok, bad]);

		expect(store.failedInstances).toEqual([{ instance: bad, kind: 'auth' }]);
		expect(store.days.flatMap((d) => d.events.map((e) => e.id))).toEqual(['x']);
		expect(store.loadState).toBe('ready');
	});

	it('reports an error only when every instance fails', async () => {
		const bad = instance('bad', 'Bad');
		mockCommunities.mockRejectedValue(new ApiError('network', 'offline', null));

		const store = createEventsStore();
		await store.load([bad]);

		expect(store.loadState).toBe('error');
		expect(store.failedInstances.map((f) => f.kind)).toEqual(['network']);
	});

	it('filters to a single community', async () => {
		const a = instance('ia', 'Alpha');
		mockCommunities.mockResolvedValue([
			community('ca', 'ca', 'Choir'),
			community('cb', 'cb', 'Book')
		]);
		mockEvents.mockImplementation(async (_inst, slug) =>
			slug === 'ca' ? [event('a', '2026-06-10T10:00:00Z')] : [event('b', '2026-06-11T10:00:00Z')]
		);

		const store = createEventsStore();
		await store.load([a]);

		store.setFilter('ia:ca');
		expect(store.days.flatMap((d) => d.events.map((e) => e.id))).toEqual(['a']);

		store.setFilter(null);
		expect(store.days.flatMap((d) => d.events.map((e) => e.id))).toEqual(['a', 'b']);
	});
});
