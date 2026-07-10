import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Community } from '$lib/feed/types.js';
import type { Instance } from '$lib/instances/types.js';
import type { SearchResults } from './api.js';

vi.mock('$lib/events/api.js', () => ({ fetchCommunities: vi.fn(), fetchGroups: vi.fn() }));
vi.mock('./api.js', async (importActual) => {
	const actual = await importActual<typeof import('./api.js')>();
	return { ...actual, search: vi.fn() };
});

import { fetchCommunities, fetchGroups } from '$lib/events/api.js';
import { FeedApiError } from '$lib/feed/api.js';
import * as api from './api.js';
import { createSearchStore } from './search-store.svelte.js';

function instance(id: string): Instance {
	return {
		id,
		baseUrl: `https://${id}.example`,
		instanceName: id,
		deviceToken: 't',
		user: { id: `${id}-u`, email: 'a@a', displayName: 'A' },
		addedAt: '2026-01-01T00:00:00Z'
	};
}

function community(id: string, name: string): Community {
	return {
		id,
		slug: id,
		name,
		description: null,
		accent_color: '#3E6B48',
		default_locale: 'en',
		listed_on_instance: false,
		require_real_names: false,
		viewer_can: []
	};
}

function results(posts: number): SearchResults {
	return {
		posts: Array.from({ length: posts }, (_, i) => ({
			id: `p${i}`,
			group_id: 'g1',
			deleted: false,
			published_at: '2026-06-01T00:00:00Z',
			pending_approval: false,
			pinned: false,
			acknowledgment_required: false,
			acknowledged_count: 0,
			my_acknowledged: false,
			reactions: {},
			my_reactions: [],
			attachments: [],
			viewer_can: []
		})),
		comments: [],
		events: [],
		files: []
	};
}

const mockCommunities = vi.mocked(fetchCommunities);
const mockGroups = vi.mocked(fetchGroups);
const mockSearch = vi.mocked(api.search);

describe('createSearchStore', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		mockGroups.mockResolvedValue([]);
	});

	it('stays idle for a blank query without fanning out', async () => {
		const store = createSearchStore();
		await store.run([instance('i1')], '   ');
		expect(store.loadState).toBe('idle');
		expect(mockCommunities).not.toHaveBeenCalled();
	});

	it('merges hits across accounts, busiest community first', async () => {
		mockCommunities.mockImplementation(async (inst) =>
			inst.id === 'ia' ? [community('ca', 'Choir')] : [community('cb', 'Cycling')]
		);
		mockSearch.mockImplementation(async (_inst, slug) => (slug === 'ca' ? results(1) : results(3)));

		const store = createSearchStore();
		await store.run([instance('ia'), instance('ib')], 'picnic');

		expect(store.loadState).toBe('ready');
		expect(store.buckets.map((bucket) => bucket.community.name)).toEqual(['Cycling', 'Choir']);
	});

	it('surfaces a failing account without blanking the rest', async () => {
		mockCommunities.mockImplementation(async (inst) => {
			if (inst.id === 'bad') throw new FeedApiError('auth', 'signed out', 401);
			return [community('c1', 'One')];
		});
		mockSearch.mockResolvedValue(results(2));

		const store = createSearchStore();
		await store.run([instance('ok'), instance('bad')], 'picnic');

		expect(store.failedInstances).toEqual([{ instance: instance('bad'), kind: 'auth' }]);
		expect(store.buckets).toHaveLength(1);
		expect(store.loadState).toBe('ready');
	});

	it("keeps an account's other communities when one community's search fails", async () => {
		mockCommunities.mockResolvedValue([community('good', 'Good'), community('bad', 'Bad')]);
		mockSearch.mockImplementation(async (_inst, slug) => {
			if (slug === 'bad') throw new api.ToolsApiError('server', 'boom', 500);
			return results(2);
		});

		const store = createSearchStore();
		await store.run([instance('i1')], 'picnic');

		// One community's transient failure must not blank the account's
		// other hits, and a partial failure is not an account-level failure.
		expect(store.buckets.map((bucket) => bucket.community.name)).toEqual(['Good']);
		expect(store.failedInstances).toEqual([]);
		expect(store.loadState).toBe('ready');
	});

	it('reports an error only when every account fails', async () => {
		mockCommunities.mockRejectedValue(new FeedApiError('network', 'offline', null));
		const store = createSearchStore();
		await store.run([instance('bad')], 'picnic');
		expect(store.loadState).toBe('error');
	});
});
