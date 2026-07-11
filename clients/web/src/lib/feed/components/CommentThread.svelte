<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { buildThreads, threadIsEmptyTombstone } from '$lib/feed/comments.js';
	import type { FeedStore } from '$lib/feed/feed-store.svelte.js';
	import type { Post } from '$lib/feed/types.js';
	import CommentComposer from './CommentComposer.svelte';
	import CommentItem from './CommentItem.svelte';

	interface Props {
		post: Post;
		store: FeedStore;
		currentUserId: string;
	}

	let { post, store, currentUserId }: Props = $props();

	// Hide fully-empty "removed" stubs (a deleted comment with no surviving
	// replies), but keep a deleted parent that still anchors replies.
	const threads = $derived(
		buildThreads(post.comments ?? []).filter((thread) => !threadIsEmptyTombstone(thread))
	);

	// Beyond a few replies, collapse the middle (SPEC §5: collapse beyond ~3).
	const COLLAPSE_AFTER = 3;
	let expanded = $state<Record<string, boolean>>({});
</script>

<div class="flex flex-col gap-4 border-t border-line pt-4">
	<CommentComposer
		id="comment-{post.id}"
		onSubmit={(body) => store.comment(post.id, { body_markdown: body })}
	/>

	{#each threads as thread (thread.comment.id)}
		{@const showAll = expanded[thread.comment.id]}
		{@const hidden = thread.replies.length - COLLAPSE_AFTER}
		{@const visibleReplies = showAll ? thread.replies : thread.replies.slice(-COLLAPSE_AFTER)}
		<div class="flex flex-col gap-3">
			<CommentItem
				comment={thread.comment}
				{currentUserId}
				onReact={(emoji) => store.reactComment(post.id, thread.comment.id, emoji)}
				onEdit={(body) => store.editComment(post.id, thread.comment.id, body)}
				onDelete={() => store.deleteComment(post.id, thread.comment.id)}
				onReply={(body) =>
					store.comment(post.id, { body_markdown: body, parent_comment_id: thread.comment.id })}
				onReport={(reason) => store.reportComment(post.id, thread.comment.id, reason)}
			/>

			{#if thread.replies.length > 0}
				<div class="flex flex-col gap-3 border-l border-line pl-3 sm:ml-4">
					{#if !showAll && hidden > 0}
						<button
							type="button"
							class="self-start text-xs text-accent hover:underline"
							onclick={() => (expanded = { ...expanded, [thread.comment.id]: true })}
						>
							{t('feed.comment.showMore', { count: String(hidden) })}
						</button>
					{/if}
					{#each visibleReplies as reply (reply.id)}
						<CommentItem
							comment={reply}
							{currentUserId}
							isReply
							onReact={(emoji) => store.reactComment(post.id, reply.id, emoji)}
							onEdit={(body) => store.editComment(post.id, reply.id, body)}
							onDelete={() => store.deleteComment(post.id, reply.id)}
							onReport={(reason) => store.reportComment(post.id, reply.id, reason)}
						/>
					{/each}
				</div>
			{/if}
		</div>
	{/each}
</div>
