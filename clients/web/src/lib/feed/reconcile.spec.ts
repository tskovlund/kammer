import { describe, expect, it } from 'vitest';
import {
	appendPage,
	latestActivityAt,
	reconcilePostEcho,
	removePost,
	sortFeed,
	upsertPost
} from './reconcile';
import type { Comment, Post } from './types';

function post(overrides: Partial<Post> = {}): Post {
	return {
		id: 'p1',
		group_id: 'g1',
		author: { type: 'user', id: 'u1', display_name: 'Alice' },
		body_markdown: 'hello',
		deleted: false,
		published_at: '2026-01-01T00:00:00Z',
		pending_approval: false,
		pinned: false,
		acknowledgment_required: false,
		acknowledged_count: 0,
		my_acknowledged: false,
		reactions: {},
		my_reactions: [],
		attachments: [],
		comments: [],
		...overrides
	};
}

function comment(overrides: Partial<Comment> = {}): Comment {
	return {
		id: 'c1',
		deleted: false,
		inserted_at: '2026-01-02T00:00:00Z',
		my_reactions: [],
		pending_approval: false,
		reactions: {},
		...overrides
	};
}

describe('sortFeed', () => {
	it('orders chronologically, newest first', () => {
		const older = post({ id: 'older', published_at: '2026-01-01T00:00:00Z' });
		const newer = post({ id: 'newer', published_at: '2026-03-01T00:00:00Z' });
		expect(sortFeed([older, newer], 'chronological').map((p) => p.id)).toEqual(['newer', 'older']);
	});

	it('keeps pinned posts first even when older', () => {
		const pinnedOld = post({ id: 'pin', published_at: '2025-01-01T00:00:00Z', pinned: true });
		const freshUnpinned = post({ id: 'fresh', published_at: '2026-06-01T00:00:00Z' });
		expect(sortFeed([freshUnpinned, pinnedOld], 'chronological').map((p) => p.id)).toEqual([
			'pin',
			'fresh'
		]);
	});

	it('activity sort bumps a post with a recent comment above a newer quiet post', () => {
		const bumped = post({
			id: 'bumped',
			published_at: '2026-01-01T00:00:00Z',
			comments: [comment({ id: 'c', inserted_at: '2026-05-01T00:00:00Z' })]
		});
		const quietNewer = post({ id: 'quiet', published_at: '2026-02-01T00:00:00Z', comments: [] });

		expect(sortFeed([quietNewer, bumped], 'activity').map((p) => p.id)).toEqual([
			'bumped',
			'quiet'
		]);
		// The same two in chronological order put the newer publish first.
		expect(sortFeed([quietNewer, bumped], 'chronological').map((p) => p.id)).toEqual([
			'quiet',
			'bumped'
		]);
	});

	it('is stable for equal timestamps (no reshuffle on re-sort)', () => {
		const a = post({ id: 'aaa', published_at: '2026-01-01T00:00:00Z' });
		const b = post({ id: 'bbb', published_at: '2026-01-01T00:00:00Z' });
		const once = sortFeed([a, b], 'chronological').map((p) => p.id);
		const twice = sortFeed(sortFeed([a, b], 'chronological'), 'chronological').map((p) => p.id);
		expect(once).toEqual(twice);
	});
});

describe('latestActivityAt', () => {
	it('ignores deleted comments when computing the bump time', () => {
		const p = post({
			published_at: '2026-01-01T00:00:00Z',
			comments: [comment({ inserted_at: '2026-09-01T00:00:00Z', deleted: true })]
		});
		expect(latestActivityAt(p)).toBe('2026-01-01T00:00:00Z');
	});

	it('uses the most recent live comment', () => {
		const p = post({
			published_at: '2026-01-01T00:00:00Z',
			comments: [
				comment({ id: 'a', inserted_at: '2026-02-01T00:00:00Z' }),
				comment({ id: 'b', inserted_at: '2026-04-01T00:00:00Z' })
			]
		});
		expect(latestActivityAt(p)).toBe('2026-04-01T00:00:00Z');
	});
});

describe('upsertPost', () => {
	it('replaces a post in place by id without duplicating it', () => {
		const original = post({ id: 'p', reactions: {} });
		const updated = post({ id: 'p', reactions: { '👍': 1 } });
		const result = upsertPost([original], updated, 'chronological');
		expect(result).toHaveLength(1);
		expect(result[0].reactions).toEqual({ '👍': 1 });
	});

	it('applying the HTTP response and the channel echo of one create yields no duplicate', () => {
		const created = post({ id: 'new', published_at: '2026-07-01T00:00:00Z' });
		let feed = upsertPost([], created, 'chronological');
		feed = upsertPost(feed, created, 'chronological'); // channel echo
		expect(feed).toHaveLength(1);
	});

	it('inserts a new post in sorted position', () => {
		const existing = post({ id: 'old', published_at: '2026-01-01T00:00:00Z' });
		const fresh = post({ id: 'fresh', published_at: '2026-08-01T00:00:00Z' });
		expect(upsertPost([existing], fresh, 'chronological').map((p) => p.id)).toEqual([
			'fresh',
			'old'
		]);
	});
});

describe('removePost', () => {
	it('drops the matching post and leaves the rest', () => {
		const a = post({ id: 'a' });
		const b = post({ id: 'b' });
		expect(removePost([a, b], 'a').map((p) => p.id)).toEqual(['b']);
	});
});

describe('appendPage', () => {
	it('appends only unseen posts, preserving the live copy on collision', () => {
		const live = post({ id: 'shared', reactions: { '👍': 5 } });
		const pageCopy = post({ id: 'shared', reactions: {} });
		const older = post({ id: 'older', published_at: '2025-01-01T00:00:00Z' });

		const result = appendPage([live], [pageCopy, older], 'chronological');
		expect(result.map((p) => p.id).sort()).toEqual(['older', 'shared']);
		expect(result.find((p) => p.id === 'shared')?.reactions).toEqual({ '👍': 5 });
	});
});

describe('reconcilePostEcho', () => {
	it('takes the echo verbatim when nothing is pending', () => {
		const existing = post({ comments: [comment({ id: 'c1' })] });
		const incoming = post({ reactions: { '👍': 1 }, comments: [] });
		const { post: merged, confirmedIds } = reconcilePostEcho(existing, incoming, new Set());
		expect(merged).toBe(incoming);
		expect(confirmedIds).toEqual([]);
	});

	it('preserves a pending comment the echo predates and does not confirm it', () => {
		const local = comment({ id: 'pending' });
		const existing = post({ comments: [local], comment_count: 1 });
		const echo = post({ reactions: { '👍': 1 }, comments: [], comment_count: 0 });

		const { post: merged, confirmedIds } = reconcilePostEcho(existing, echo, new Set(['pending']));
		expect(merged.comments?.map((c) => c.id)).toEqual(['pending']);
		expect(merged.reactions).toEqual({ '👍': 1 });
		expect(merged.comment_count).toBe(1);
		expect(confirmedIds).toEqual([]);
	});

	it('confirms a pending comment the echo now carries and takes the echo as-is', () => {
		const local = comment({ id: 'pending' });
		const existing = post({ comments: [local], comment_count: 1 });
		const echo = post({ comments: [local], comment_count: 1 });

		const { post: merged, confirmedIds } = reconcilePostEcho(existing, echo, new Set(['pending']));
		expect(merged).toBe(echo);
		expect(confirmedIds).toEqual(['pending']);
	});
});
