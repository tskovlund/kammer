import { describe, expect, it } from 'vitest';
import type { Group } from '$lib/feed/api.js';
import type { Community } from '$lib/feed/types.js';
import type { Instance } from '$lib/instances/types.js';
import type { SearchResults } from './api.js';
import { buildBuckets, groupSlugMap, hitCount, type CommunitySearch } from './search.js';

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

const group: Group = {
	id: 'g1',
	name: 'Crew',
	slug: 'crew',
	visibility: 'community',
	join_policy: 'open',
	features: [],
	sealed: false,
	archived: false,
	viewer_can: []
};

describe('hitCount', () => {
	it('sums every section', () => {
		expect(hitCount(results(3))).toBe(3);
		expect(hitCount(results(0))).toBe(0);
	});
});

describe('groupSlugMap', () => {
	it('maps group id to slug for deep links', () => {
		expect(groupSlugMap([group])).toEqual({ g1: 'crew' });
	});
});

describe('buildBuckets', () => {
	it('drops empty communities and orders the rest by hit count', () => {
		const searches: CommunitySearch[] = [
			{
				instance: instance('i1'),
				community: community('c1', 'Quiet'),
				results: results(1),
				groups: [group]
			},
			{
				instance: instance('i1'),
				community: community('c2', 'Busy'),
				results: results(4),
				groups: [group]
			},
			{
				instance: instance('i1'),
				community: community('c3', 'Empty'),
				results: results(0),
				groups: [group]
			}
		];
		const buckets = buildBuckets(searches);
		expect(buckets.map((bucket) => bucket.community.name)).toEqual(['Busy', 'Quiet']);
		expect(buckets[0]?.groupSlugById).toEqual({ g1: 'crew' });
	});
});
