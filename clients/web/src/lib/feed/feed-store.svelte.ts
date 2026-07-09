import type { Instance } from '$lib/instances/types.js';
import { getSocket, noteInstanceAuthFailure } from '$lib/realtime/registry.svelte.js';
import * as api from './api.js';
import { FeedApiError, type CreatePostInput, type FeedErrorKind } from './api.js';
import { SvelteSet } from 'svelte/reactivity';
import { applyOptimisticVote, toggleReaction } from './interactions.js';
import { appendPage, reconcilePostEcho, sortFeed } from './reconcile.js';
import type { Comment, FeedSort, Post } from './types.js';

interface GroupRef {
	community: string;
	group: string;
}

export interface FeedActionError {
	kind: FeedErrorKind;
	message: string;
}

type LoadState = 'idle' | 'loading' | 'ready' | 'error';

/**
 * The reactive data layer for one group's feed: it owns the post list, drives
 * cursor pagination and the sort toggle, applies optimistic writes (reactions,
 * votes) that the server response then confirms, and merges live channel
 * events. Ordering and merge rules live in the pure `reconcile`/`interactions`
 * modules (unit-tested); this store is the orchestration around them.
 *
 * All writes are id-keyed, so a write's HTTP response and the feed channel's
 * echo of the same change converge on one post without duplicating it.
 */
export function createFeedStore(instance: Instance, ref: GroupRef, groupId: string) {
	let posts = $state<Post[]>([]);
	let sort = $state<FeedSort>('chronological');
	let loadState = $state<LoadState>('idle');
	let loadErrorKind = $state<FeedErrorKind | null>(null);
	let nextCursor = $state<string | null>(null);
	let loadingMore = $state(false);
	let actionError = $state<FeedActionError | null>(null);
	let stopLive: (() => void) | null = null;

	// Ids of comments this client just created that haven't yet appeared in a
	// `post_updated` echo. They're preserved across a concurrent echo that
	// predates them (see `applyEcho`), then dropped once the echo confirms them.
	const pendingCommentIds = new SvelteSet<string>();

	const items = $derived(sortFeed(posts, sort));

	function replace(post: Post): void {
		const index = posts.findIndex((existing) => existing.id === post.id);
		if (index === -1) posts = [...posts, post];
		else posts = posts.map((existing) => (existing.id === post.id ? post : existing));
	}

	/** Apply a `post_updated` echo, preserving just-created comments it predates. */
	function applyEcho(incoming: Post): void {
		const { post, confirmedIds } = reconcilePostEcho(
			find(incoming.id),
			incoming,
			pendingCommentIds
		);
		for (const id of confirmedIds) pendingCommentIds.delete(id);
		replace(post);
	}

	function drop(postId: string): void {
		posts = posts.filter((post) => post.id !== postId);
	}

	function find(postId: string): Post | undefined {
		return posts.find((post) => post.id === postId);
	}

	function handle(error: unknown): void {
		if (error instanceof FeedApiError) {
			if (error.kind === 'auth') noteInstanceAuthFailure(instance);
			actionError = { kind: error.kind, message: error.message };
		} else {
			actionError = { kind: 'server', message: 'Something went wrong.' };
		}
	}

	async function load(): Promise<void> {
		loadState = 'loading';
		loadErrorKind = null;
		pendingCommentIds.clear();
		try {
			const page = await api.fetchFeedPage(instance, ref);
			posts = page.posts;
			nextCursor = page.nextCursor;
			loadState = 'ready';
		} catch (error) {
			if (error instanceof FeedApiError) {
				loadErrorKind = error.kind;
				if (error.kind === 'auth') noteInstanceAuthFailure(instance);
			} else {
				loadErrorKind = 'server';
			}
			loadState = 'error';
		}
	}

	async function loadMore(): Promise<void> {
		if (loadingMore || !nextCursor) return;
		loadingMore = true;
		try {
			const page = await api.fetchFeedPage(instance, ref, nextCursor);
			// appendPage dedupes by id (keeping the live copy) and sorts; the
			// derived `items` re-sorts anyway, so this only needs to merge.
			posts = appendPage(posts, page.posts, sort);
			nextCursor = page.nextCursor;
		} catch (error) {
			handle(error);
		} finally {
			loadingMore = false;
		}
	}

	/** Begin live updates over the instance's feed channel. Idempotent. */
	function startLive(): void {
		if (stopLive) return;
		stopLive = getSocket(instance).subscribeFeed(groupId, {
			onPostCreated: (post) => replace(post),
			onPostUpdated: (post) => applyEcho(post),
			onPostDeleted: (postId) => drop(postId)
		});
	}

	function stop(): void {
		stopLive?.();
		stopLive = null;
	}

	async function react(postId: string, emoji: string): Promise<void> {
		const current = find(postId);
		if (!current) return;
		// Optimistic: reflect the toggle instantly, reconcile on the response.
		const wasMine = current.my_reactions.includes(emoji);
		replace({ ...current, ...toggleReaction(current, emoji) });
		try {
			replace(await api.reactToPost(instance, ref, postId, emoji));
		} catch (error) {
			// Restore *our* membership for this emoji to its pre-optimistic value,
			// re-deriving from the latest copy instead of blanket-restoring a
			// snapshot. If a concurrent echo already reconciled us to server truth
			// (a full post_updated swap, which drops our in-flight reaction), our
			// membership matches `wasMine` and we leave it — so another viewer's
			// reaction counted by that echo isn't clobbered, and we don't resurrect
			// the reaction our own request just failed to make.
			const latest = find(postId);
			if (latest && latest.my_reactions.includes(emoji) !== wasMine) {
				replace({ ...latest, ...toggleReaction(latest, emoji) });
			}
			handle(error);
		}
	}

	async function vote(postId: string, optionIds: string[]): Promise<void> {
		const current = find(postId);
		if (!current?.poll) return;
		const previousVotes = [...current.poll.my_votes];
		replace({ ...current, poll: applyOptimisticVote(current.poll, optionIds) });
		try {
			const poll = await api.votePoll(instance, ref, postId, optionIds);
			const latest = find(postId);
			if (latest) replace({ ...latest, poll });
		} catch (error) {
			// Re-derive the inverse selection on the latest poll instead of
			// restoring the pre-vote snapshot, so another viewer's vote counted
			// mid-flight isn't discarded when our optimistic vote rolls back.
			const latest = find(postId);
			if (latest?.poll) {
				replace({ ...latest, poll: applyOptimisticVote(latest.poll, previousVotes) });
			}
			handle(error);
		}
	}

	async function acknowledge(postId: string): Promise<void> {
		try {
			replace(await api.acknowledgePost(instance, ref, postId));
		} catch (error) {
			handle(error);
		}
	}

	async function setPinned(postId: string, pinned: boolean): Promise<void> {
		try {
			replace(await api.setPinned(instance, ref, postId, pinned));
		} catch (error) {
			handle(error);
		}
	}

	async function publish(input: CreatePostInput): Promise<boolean> {
		try {
			// Post-then-insert (not blind-optimistic): a create can fail on
			// posting rights, rate limits, or upload references, and the
			// authoritative post carries server-assigned ids the composer can't
			// know. Id-keyed insert dedupes against the channel echo.
			replace(await api.createPost(instance, ref, input));
			return true;
		} catch (error) {
			handle(error);
			return false;
		}
	}

	async function editPost(postId: string, body: string): Promise<boolean> {
		try {
			replace(await api.editPost(instance, ref, postId, body));
			return true;
		} catch (error) {
			handle(error);
			return false;
		}
	}

	async function deletePost(postId: string, options: { hard?: boolean } = {}): Promise<void> {
		try {
			const result = await api.deletePost(instance, ref, postId, options);
			if (options.hard) drop(postId);
			else replace(result); // soft delete leaves a tombstone in the thread
		} catch (error) {
			handle(error);
		}
	}

	function mergeComment(postId: string, comment: Comment): void {
		const post = find(postId);
		if (!post) return;
		const comments = post.comments ?? [];
		const index = comments.findIndex((existing) => existing.id === comment.id);
		const isNew = index === -1;
		const nextComments = isNew
			? [...comments, comment]
			: comments.map((existing) => (existing.id === comment.id ? comment : existing));
		replace({
			...post,
			comments: nextComments,
			// Only a brand-new comment moves the count (+1) — an edit, react, or
			// soft-delete-to-tombstone leaves it. Never recompute from the array:
			// the feed's embedded list may be partial, and the server counts
			// tombstones and replies differently than a naive filter would. The
			// channel's `post_updated` echo carries the authoritative count.
			comment_count: isNew ? (post.comment_count ?? 0) + 1 : post.comment_count
		});
	}

	async function comment(
		postId: string,
		input: { body_markdown: string; parent_comment_id?: string | null }
	): Promise<boolean> {
		try {
			const created = await api.createComment(instance, ref, postId, input);
			// Track it until its own echo confirms it, so a concurrent echo that
			// predates it (built before it committed) can't momentarily drop it.
			pendingCommentIds.add(created.id);
			mergeComment(postId, created);
			return true;
		} catch (error) {
			handle(error);
			return false;
		}
	}

	async function editComment(postId: string, commentId: string, body: string): Promise<boolean> {
		try {
			mergeComment(postId, await api.editComment(instance, ref, postId, commentId, body));
			return true;
		} catch (error) {
			handle(error);
			return false;
		}
	}

	async function deleteComment(postId: string, commentId: string): Promise<void> {
		try {
			mergeComment(postId, await api.deleteComment(instance, ref, postId, commentId));
		} catch (error) {
			handle(error);
		}
	}

	async function reactComment(postId: string, commentId: string, emoji: string): Promise<void> {
		const post = find(postId);
		const target = post?.comments?.find((c) => c.id === commentId);
		if (!post || !target) return;
		const wasMine = target.my_reactions.includes(emoji);
		mergeComment(postId, { ...target, ...toggleReaction(target, emoji) });
		try {
			mergeComment(postId, await api.reactToComment(instance, ref, postId, commentId, emoji));
		} catch (error) {
			// Restore our membership to its pre-optimistic value on the latest copy
			// of the comment, leaving it untouched if a concurrent echo already
			// reconciled us — mirrors `react`'s conditional rollback.
			const latest = find(postId)?.comments?.find((c) => c.id === commentId);
			if (latest && latest.my_reactions.includes(emoji) !== wasMine) {
				mergeComment(postId, { ...latest, ...toggleReaction(latest, emoji) });
			}
			handle(error);
		}
	}

	return {
		get items() {
			return items;
		},
		get sort() {
			return sort;
		},
		get loadState() {
			return loadState;
		},
		get loadErrorKind() {
			return loadErrorKind;
		},
		get hasMore() {
			return nextCursor !== null;
		},
		get loadingMore() {
			return loadingMore;
		},
		get actionError() {
			return actionError;
		},
		setSort(next: FeedSort) {
			sort = next;
		},
		clearActionError() {
			actionError = null;
		},
		load,
		loadMore,
		startLive,
		stop,
		react,
		vote,
		acknowledge,
		setPinned,
		publish,
		editPost,
		deletePost,
		comment,
		editComment,
		deleteComment,
		reactComment
	};
}

export type FeedStore = ReturnType<typeof createFeedStore>;
