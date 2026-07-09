import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { FeedHandlers } from '$lib/realtime/manager.js';
import type { Instance } from '$lib/instances/types.js';
import type { Comment, Post } from './types.js';

// Capture the feed channel handlers the store wires up in `startLive`, so a
// test can push `post_updated` echoes as the live channel would.
const { subscribeFeed, feedHandlers } = vi.hoisted(() => {
	const feedHandlers: { current: FeedHandlers | null } = { current: null };
	const subscribeFeed = vi.fn((_groupId: string, handlers: FeedHandlers) => {
		feedHandlers.current = handlers;
		return () => {};
	});
	return { subscribeFeed, feedHandlers };
});

vi.mock('$lib/realtime/registry.svelte.js', () => ({
	getSocket: () => ({ subscribeFeed }),
	noteInstanceAuthFailure: vi.fn()
}));

vi.mock('./api.js', async (importActual) => {
	const actual = await importActual<typeof import('./api.js')>();
	return {
		...actual,
		fetchFeedPage: vi.fn(),
		createComment: vi.fn(),
		reactToPost: vi.fn(),
		votePoll: vi.fn(),
		reactToComment: vi.fn()
	};
});

import * as api from './api.js';
import { FeedApiError } from './api.js';
import { createFeedStore } from './feed-store.svelte.js';

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

const ref = { community: 'c', group: 'g' };

function post(overrides: Partial<Post> = {}): Post {
	return {
		id: 'p1',
		group_id: 'g1',
		acknowledged_count: 0,
		acknowledgment_required: false,
		attachments: [],
		deleted: false,
		my_acknowledged: false,
		my_reactions: [],
		pending_approval: false,
		pinned: false,
		published_at: '2026-01-01T00:00:00Z',
		reactions: {},
		viewer_can: [],
		comment_count: 0,
		comments: [],
		...overrides
	};
}

function comment(overrides: Partial<Comment> = {}): Comment {
	return {
		id: 'c1',
		deleted: false,
		inserted_at: '2026-01-01T00:00:00Z',
		my_reactions: [],
		pending_approval: false,
		reactions: {},
		body_markdown: 'hi',
		...overrides
	};
}

async function readyStore(initial: Post) {
	vi.mocked(api.fetchFeedPage).mockResolvedValue({ posts: [initial], nextCursor: null });
	const store = createFeedStore(instance(), ref, 'g1');
	await store.load();
	store.startLive();
	return store;
}

function pushEcho(next: Post): void {
	if (!feedHandlers.current?.onPostUpdated) throw new Error('no live handler wired');
	feedHandlers.current.onPostUpdated(next);
}

beforeEach(() => {
	vi.clearAllMocks();
	feedHandlers.current = null;
});

describe('optimistic comment vs. concurrent echo (finding 1)', () => {
	it('preserves a just-created comment when a concurrent echo omits it', async () => {
		const store = await readyStore(post({ comments: [], comment_count: 0 }));

		const created = comment({ id: 'new-comment' });
		vi.mocked(api.createComment).mockResolvedValue(created);
		await store.comment('p1', { body_markdown: 'hi' });
		expect(store.items[0].comments?.map((c) => c.id)).toEqual(['new-comment']);

		// A concurrent post_updated echo (e.g. another viewer's reaction) built
		// before our comment committed — it carries the new reaction but not the
		// comment. The comment must survive rather than blink out.
		pushEcho(post({ reactions: { '👍': 1 }, comments: [], comment_count: 0 }));

		const merged = store.items[0];
		expect(merged.reactions).toEqual({ '👍': 1 });
		expect(merged.comments?.map((c) => c.id)).toEqual(['new-comment']);
		expect(merged.comment_count).toBe(1);
	});

	it('defers to the echo once it confirms the comment, then honours deletions', async () => {
		const store = await readyStore(post({ comments: [], comment_count: 0 }));
		const created = comment({ id: 'new-comment' });
		vi.mocked(api.createComment).mockResolvedValue(created);
		await store.comment('p1', { body_markdown: 'hi' });

		// The comment's own echo arrives and carries it — now authoritative.
		pushEcho(post({ comments: [created], comment_count: 1 }));
		expect(store.items[0].comments?.map((c) => c.id)).toEqual(['new-comment']);

		// A later echo that omits the (now confirmed) comment is a real deletion
		// and must be honoured, not treated as a stale-echo miss.
		pushEcho(post({ comments: [], comment_count: 0 }));
		expect(store.items[0].comments).toEqual([]);
		expect(store.items[0].comment_count).toBe(0);
	});
});

describe('optimistic reaction rollback vs. concurrent reaction (finding 2)', () => {
	it('keeps a concurrent reaction that arrived mid-flight when our react fails', async () => {
		const store = await readyStore(post({ reactions: {}, my_reactions: [] }));

		// Our request will fail; before it does, a concurrent echo lands adding
		// another viewer's reaction (a full post swap, server truth without our
		// in-flight reaction).
		vi.mocked(api.reactToPost).mockImplementation(async () => {
			pushEcho(post({ reactions: { '👍': 1 }, my_reactions: [] }));
			throw new FeedApiError('server', 'nope', 500);
		});

		await store.react('p1', '❤️');

		const result = store.items[0];
		// The other viewer's reaction survives; our failed reaction is not
		// resurrected on top of it.
		expect(result.reactions).toEqual({ '👍': 1 });
		expect(result.my_reactions).toEqual([]);
	});

	it('rolls our reaction back cleanly when no echo intervenes', async () => {
		const store = await readyStore(post({ reactions: {}, my_reactions: [] }));
		vi.mocked(api.reactToPost).mockRejectedValue(new FeedApiError('server', 'nope', 500));

		await store.react('p1', '❤️');

		expect(store.items[0].reactions).toEqual({});
		expect(store.items[0].my_reactions).toEqual([]);
	});
});

describe('optimistic vote rollback vs. concurrent vote (finding 2)', () => {
	const withPoll = () =>
		post({
			poll: {
				id: 'poll-1',
				anonymous: false,
				multiple_choice: false,
				my_votes: [],
				options: [
					{ id: 'o1', text: 'A', votes: 0 },
					{ id: 'o2', text: 'B', votes: 0 }
				]
			}
		});

	it('keeps a concurrent vote that arrived mid-flight when our vote fails', async () => {
		const store = await readyStore(withPoll());

		vi.mocked(api.votePoll).mockImplementation(async () => {
			// Another viewer voted for o2 — echoed as server truth without our vote.
			pushEcho(
				post({
					poll: {
						id: 'poll-1',
						anonymous: false,
						multiple_choice: false,
						my_votes: [],
						options: [
							{ id: 'o1', text: 'A', votes: 0 },
							{ id: 'o2', text: 'B', votes: 1 }
						]
					}
				})
			);
			throw new FeedApiError('server', 'nope', 500);
		});

		await store.vote('p1', ['o1']);

		const poll = store.items[0].poll!;
		expect(poll.my_votes).toEqual([]);
		expect(poll.options.find((o) => o.id === 'o2')?.votes).toBe(1);
		expect(poll.options.find((o) => o.id === 'o1')?.votes).toBe(0);
	});
});
