import type { Comment } from './types.js';

export interface CommentThread {
	comment: Comment;
	replies: Comment[];
}

/**
 * Build the one-level thread model (SPEC §5: exactly one reply level) from
 * the flat comment list the serializer returns. Each comment carries
 * `parent_comment_id`; top-level comments (null parent) are ordered oldest
 * first, and each keeps its replies oldest first beneath it. A reply whose
 * parent is missing (e.g. a hard-deleted parent that left no tombstone) is
 * promoted to a top-level entry rather than silently dropped.
 */
export function buildThreads(comments: Comment[]): CommentThread[] {
	const byParent = new Map<string, Comment[]>();
	const topLevel: Comment[] = [];
	const ids = new Set(comments.map((comment) => comment.id));

	for (const comment of comments) {
		const parentId = comment.parent_comment_id;
		if (parentId && ids.has(parentId)) {
			const siblings = byParent.get(parentId) ?? [];
			siblings.push(comment);
			byParent.set(parentId, siblings);
		} else {
			topLevel.push(comment);
		}
	}

	const byInsertedAt = (a: Comment, b: Comment) => a.inserted_at.localeCompare(b.inserted_at);

	return topLevel.sort(byInsertedAt).map((comment) => ({
		comment,
		replies: (byParent.get(comment.id) ?? []).sort(byInsertedAt)
	}));
}

/**
 * A soft-deleted top-level comment with no surviving replies contributes
 * nothing but a "removed" stub; callers can hide fully-empty deleted threads.
 * A deleted comment that still has replies must stay (thread coherence).
 */
export function threadIsEmptyTombstone(thread: CommentThread): boolean {
	return thread.comment.deleted && thread.replies.length === 0;
}
