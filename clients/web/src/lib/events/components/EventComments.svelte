<script lang="ts">
	import { buildThreads, threadIsEmptyTombstone } from '$lib/feed/comments.js';
	import CommentComposer from '$lib/feed/components/CommentComposer.svelte';
	import CommentItem from '$lib/feed/components/CommentItem.svelte';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import type { EventStore } from '../event-store.svelte.js';
	import type { Comment } from '../types.js';

	interface Props {
		comments: Comment[];
		store: EventStore;
		currentUserId: string;
		locked: boolean;
	}

	let { comments, store, currentUserId, locked }: Props = $props();

	// One reply level, same thread model as the feed (SPEC §5). Fully-empty
	// "removed" stubs are hidden; a deleted parent with replies stays.
	const threads = $derived(
		buildThreads(comments).filter((thread) => !threadIsEmptyTombstone(thread))
	);

	const COLLAPSE_AFTER = 3;
	let expanded = $state<Record<string, boolean>>({});
</script>

<section class="flex flex-col gap-4 border-t border-line pt-5" aria-label={t('feed.comment.add')}>
	{#if locked}
		<p class="text-sm text-ink-faint italic">{t('events.detail.commentsLocked')}</p>
	{:else}
		<CommentComposer
			id="event-comment"
			onSubmit={(body) => store.comment({ body_markdown: body })}
		/>
	{/if}

	{#each threads as thread (thread.comment.id)}
		{@const showAll = expanded[thread.comment.id]}
		{@const hidden = thread.replies.length - COLLAPSE_AFTER}
		{@const visibleReplies = showAll ? thread.replies : thread.replies.slice(-COLLAPSE_AFTER)}
		<div class="flex flex-col gap-3">
			<CommentItem
				comment={thread.comment}
				{currentUserId}
				onReact={(emoji) => store.reactComment(thread.comment.id, emoji)}
				onEdit={(body) => store.editComment(thread.comment.id, body)}
				onDelete={() => store.deleteComment(thread.comment.id)}
				onReply={locked
					? undefined
					: (body) => store.comment({ body_markdown: body, parent_comment_id: thread.comment.id })}
				onReport={(reason) => store.reportComment(thread.comment.id, reason)}
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
							onReact={(emoji) => store.reactComment(reply.id, emoji)}
							onEdit={(body) => store.editComment(reply.id, body)}
							onDelete={() => store.deleteComment(reply.id)}
							onReport={(reason) => store.reportComment(reply.id, reason)}
						/>
					{/each}
				</div>
			{/if}
		</div>
	{/each}
</section>
