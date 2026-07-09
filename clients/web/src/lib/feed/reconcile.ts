import type { FeedSort, Post } from './types.js';

/**
 * Pure feed-list reconciliation, kept separate from the reactive store so
 * the ordering rules (SPEC §5: strictly chronological + pinned-first, or the
 * activity/bump view) and the live-update merge (channel `post_created` /
 * `post_updated` / `post_deleted`, plus the write responses) are unit-tested
 * without a component harness.
 *
 * Everything here is id-keyed and idempotent: a write's HTTP response and the
 * channel echo of the same change both flow through `upsertPost`, so applying
 * both never duplicates a post.
 */

/**
 * The timestamp a post sorts by in the activity view: the most recent of its
 * own publication and any of its (non-deleted) comments. Comments arrive as a
 * flat list carrying `parent_comment_id`, so this covers replies too.
 */
export function latestActivityAt(post: Post): string {
	let latest = post.published_at;
	for (const comment of post.comments ?? []) {
		if (comment.deleted) continue;
		if (comment.inserted_at > latest) latest = comment.inserted_at;
	}
	return latest;
}

function comparePosts(a: Post, b: Post, sort: FeedSort): number {
	// Pinned posts always lead, regardless of sort (SPEC §5 announcement toolkit).
	if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
	const aKey = sort === 'activity' ? latestActivityAt(a) : a.published_at;
	const bKey = sort === 'activity' ? latestActivityAt(b) : b.published_at;
	if (aKey !== bKey) return aKey < bKey ? 1 : -1; // newest first
	// Stable tiebreak so equal timestamps don't reorder on every re-sort.
	return a.id < b.id ? 1 : a.id > b.id ? -1 : 0;
}

/** Order a feed page: pinned-first, then by the chosen sort, newest first. */
export function sortFeed(posts: Post[], sort: FeedSort): Post[] {
	return [...posts].sort((a, b) => comparePosts(a, b, sort));
}

/**
 * Insert or replace a post by id, returning a newly sorted array. A
 * hard-deleted post arrives via `removePost`; a soft-deleted one arrives here
 * as an ordinary updated post whose `deleted` flag is now set (the tombstone
 * stays in the thread, SPEC §5).
 */
export function upsertPost(posts: Post[], incoming: Post, sort: FeedSort): Post[] {
	const next = posts.filter((post) => post.id !== incoming.id);
	next.push(incoming);
	return sortFeed(next, sort);
}

/** Remove a post by id (hard delete / `post_deleted`). */
export function removePost(posts: Post[], postId: string): Post[] {
	return posts.filter((post) => post.id !== postId);
}

/**
 * Merge a freshly fetched page onto the existing list (cursor pagination):
 * existing posts win on id collision only if the incoming copy is not newer —
 * but since a later page is always older, incoming rarely collides. We keep
 * the existing (possibly live-updated) copy on collision and append the rest.
 */
export function appendPage(posts: Post[], page: Post[], sort: FeedSort): Post[] {
	const seen = new Set(posts.map((post) => post.id));
	const merged = [...posts];
	for (const post of page) {
		if (!seen.has(post.id)) {
			merged.push(post);
			seen.add(post.id);
		}
	}
	return sortFeed(merged, sort);
}
