import { describe, expect, it } from 'vitest';
import { communitiesInFeed, groupByCommunity } from './group-by-community';
import type { MergedEvent, MergedPost } from '$lib/instances/home';
import type { Instance } from '$lib/instances/types';

function instance(id: string, name = id): Instance {
	return {
		id,
		baseUrl: `https://${id}.example.com`,
		instanceName: name,
		deviceToken: `token-${id}`,
		user: { id: `u-${id}`, email: `a@${id}.example.com`, displayName: 'A' },
		addedAt: '2026-01-01T00:00:00Z'
	};
}

function post(overrides: {
	id: string;
	instance: Instance;
	community: { id: string; name: string; slug: string };
	published_at: string;
}): MergedPost {
	return {
		id: overrides.id,
		group_id: 'g1',
		author: { type: 'user', id: 'u1', display_name: 'A' },
		body_markdown: 'hi',
		deleted: false,
		published_at: overrides.published_at,
		pending_approval: false,
		pinned: false,
		acknowledgment_required: false,
		acknowledged_count: 0,
		my_acknowledged: false,
		reactions: {},
		my_reactions: [],
		attachments: [],
		viewer_can: [],
		comments: [],
		community: { ...overrides.community, description: null, viewer_can: [] },
		group: { id: 'g1', name: 'Group', slug: 'group' },
		instance: overrides.instance
	};
}

function event(overrides: {
	id: string;
	instance: Instance;
	community: { id: string; name: string; slug: string };
	starts_at: string;
}): MergedEvent {
	return {
		id: overrides.id,
		group_id: 'g1',
		title: 'Rehearsal',
		starts_at: overrides.starts_at,
		all_day: false,
		timezone: 'UTC',
		cancelled: false,
		comments_locked: false,
		rsvp_counts: { yes: 0, maybe: 0, no: 0 },
		slots: [],
		comments: [],
		community: { ...overrides.community, description: null, viewer_can: [] },
		group: { id: 'g1', name: 'Group', slug: 'group' },
		instance: overrides.instance
	};
}

const bandCommunity = { id: 'c-band', name: 'The Band', slug: 'band' };
const clubCommunity = { id: 'c-club', name: 'Chess Club', slug: 'club' };

describe('groupByCommunity', () => {
	it('buckets posts and events under their community', () => {
		const i = instance('one');
		const buckets = groupByCommunity(
			[post({ id: 'p1', instance: i, community: bandCommunity, published_at: '2026-05-01' })],
			[event({ id: 'e1', instance: i, community: bandCommunity, starts_at: '2026-06-01' })]
		);
		expect(buckets).toHaveLength(1);
		expect(buckets[0].key.communityName).toBe('The Band');
		expect(buckets[0].posts.map((p) => p.id)).toEqual(['p1']);
		expect(buckets[0].events.map((e) => e.id)).toEqual(['e1']);
	});

	it('keeps same-slug communities on different instances in separate buckets', () => {
		const a = instance('a');
		const b = instance('b');
		const sameSlug = { id: 'c-a', name: 'Alpha', slug: 'shared' };
		const sameSlugOther = { id: 'c-b', name: 'Beta', slug: 'shared' };

		const buckets = groupByCommunity(
			[
				post({ id: 'pa', instance: a, community: sameSlug, published_at: '2026-01-01' }),
				post({ id: 'pb', instance: b, community: sameSlugOther, published_at: '2026-01-02' })
			],
			[]
		);
		expect(buckets).toHaveLength(2);
		expect(new Set(buckets.map((bucket) => bucket.key.id)).size).toBe(2);
	});

	it('orders buckets by most recent activity, liveliest first', () => {
		const i = instance('one');
		const buckets = groupByCommunity(
			[
				post({ id: 'quiet', instance: i, community: clubCommunity, published_at: '2026-01-01' }),
				post({ id: 'lively', instance: i, community: bandCommunity, published_at: '2026-09-01' })
			],
			[]
		);
		expect(buckets.map((bucket) => bucket.key.communityName)).toEqual(['The Band', 'Chess Club']);
	});

	it('ranks a community with a recent post above one whose only signal is a future event', () => {
		const i = instance('one');
		const buckets = groupByCommunity(
			[post({ id: 'p', instance: i, community: clubCommunity, published_at: '2026-05-01' })],
			[event({ id: 'e', instance: i, community: bandCommunity, starts_at: '2026-09-01' })]
		);
		// The far-future event must not lift the band community above the club's
		// recent post — recent chatter leads, post-less communities fall back.
		expect(buckets.map((bucket) => bucket.key.communityName)).toEqual(['Chess Club', 'The Band']);
	});

	it('orders post-less communities by their soonest upcoming event', () => {
		const i = instance('one');
		const buckets = groupByCommunity(
			[],
			[
				event({ id: 'later', instance: i, community: clubCommunity, starts_at: '2026-12-01' }),
				event({ id: 'sooner', instance: i, community: bandCommunity, starts_at: '2026-08-01' })
			]
		);
		expect(buckets.map((bucket) => bucket.key.communityName)).toEqual(['The Band', 'Chess Club']);
	});

	it('lists the distinct communities for the filter chips', () => {
		const i = instance('one');
		const buckets = groupByCommunity(
			[
				post({ id: 'p1', instance: i, community: bandCommunity, published_at: '2026-05-01' }),
				post({ id: 'p2', instance: i, community: clubCommunity, published_at: '2026-04-01' })
			],
			[]
		);
		expect(
			communitiesInFeed(buckets)
				.map((key) => key.communitySlug)
				.sort()
		).toEqual(['band', 'club']);
	});
});
