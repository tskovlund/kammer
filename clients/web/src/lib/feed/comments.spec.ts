import { describe, expect, it } from 'vitest';
import { buildThreads, threadIsEmptyTombstone } from './comments';
import type { Comment } from './types';

function comment(overrides: Partial<Comment> = {}): Comment {
	return {
		id: 'c1',
		deleted: false,
		inserted_at: '2026-01-01T00:00:00Z',
		my_reactions: [],
		pending_approval: false,
		reactions: {},
		parent_comment_id: null,
		...overrides
	};
}

describe('buildThreads', () => {
	it('nests replies one level under their parent, oldest first', () => {
		const parent = comment({ id: 'p', inserted_at: '2026-01-01T00:00:00Z' });
		const reply2 = comment({
			id: 'r2',
			parent_comment_id: 'p',
			inserted_at: '2026-01-03T00:00:00Z'
		});
		const reply1 = comment({
			id: 'r1',
			parent_comment_id: 'p',
			inserted_at: '2026-01-02T00:00:00Z'
		});

		const threads = buildThreads([reply2, parent, reply1]);
		expect(threads).toHaveLength(1);
		expect(threads[0].comment.id).toBe('p');
		expect(threads[0].replies.map((r) => r.id)).toEqual(['r1', 'r2']);
	});

	it('orders top-level comments oldest first', () => {
		const first = comment({ id: 'first', inserted_at: '2026-01-01T00:00:00Z' });
		const second = comment({ id: 'second', inserted_at: '2026-02-01T00:00:00Z' });
		expect(buildThreads([second, first]).map((t) => t.comment.id)).toEqual(['first', 'second']);
	});

	it('promotes an orphaned reply (missing parent) to top level rather than dropping it', () => {
		const orphan = comment({ id: 'orphan', parent_comment_id: 'gone' });
		expect(buildThreads([orphan]).map((t) => t.comment.id)).toEqual(['orphan']);
	});

	it('keeps a deleted parent that still has replies', () => {
		const parent = comment({ id: 'p', deleted: true });
		const reply = comment({ id: 'r', parent_comment_id: 'p' });
		const threads = buildThreads([parent, reply]);
		expect(threads).toHaveLength(1);
		expect(threads[0].replies.map((r) => r.id)).toEqual(['r']);
	});
});

describe('threadIsEmptyTombstone', () => {
	it('is true for a deleted comment with no replies', () => {
		expect(threadIsEmptyTombstone({ comment: comment({ deleted: true }), replies: [] })).toBe(true);
	});

	it('is false when the deleted comment still has replies', () => {
		expect(
			threadIsEmptyTombstone({ comment: comment({ deleted: true }), replies: [comment()] })
		).toBe(false);
	});

	it('is false for a live comment', () => {
		expect(threadIsEmptyTombstone({ comment: comment({ deleted: false }), replies: [] })).toBe(
			false
		);
	});
});
