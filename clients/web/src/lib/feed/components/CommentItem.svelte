<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import type { Comment } from '$lib/feed/types.js';
	import Avatar from '$lib/ui/Avatar.svelte';
	import Markdown from '$lib/ui/Markdown.svelte';
	import RelativeTime from '$lib/ui/RelativeTime.svelte';
	import CommentComposer from './CommentComposer.svelte';
	import ReactionBar from './ReactionBar.svelte';

	interface Props {
		comment: Comment;
		currentUserId: string;
		isReply?: boolean;
		onReact: (emoji: string) => void;
		onEdit: (body: string) => Promise<boolean>;
		onDelete: () => void;
		/** Absent for replies (one reply level only, SPEC §5). */
		onReply?: (body: string) => Promise<boolean>;
		/** Report to the moderators (issues #256/#262). */
		onReport?: (reason: string) => Promise<boolean>;
	}

	let {
		comment,
		currentUserId,
		isReply = false,
		onReact,
		onEdit,
		onDelete,
		onReply,
		onReport
	}: Props = $props();

	const isMine = $derived(comment.author?.type === 'user' && comment.author.id === currentUserId);
	let editing = $state(false);
	let replying = $state(false);
	let reporting = $state(false);
	let reported = $state(false);

	async function sendReport(reason: string): Promise<boolean> {
		if (!onReport) return false;
		const ok = await onReport(reason);
		if (ok) {
			reporting = false;
			reported = true;
		}
		return ok;
	}

	async function saveEdit(body: string): Promise<boolean> {
		const ok = await onEdit(body);
		if (ok) editing = false;
		return ok;
	}

	async function sendReply(body: string): Promise<boolean> {
		if (!onReply) return false;
		const ok = await onReply(body);
		if (ok) replying = false;
		return ok;
	}
</script>

<div class="flex gap-2.5">
	<Avatar author={comment.author} size="sm" />
	<div class="min-w-0 flex-1">
		<div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5 text-sm">
			<span class="font-medium text-ink"
				>{comment.author?.display_name ?? t('feed.author.unknown')}</span
			>
			{#if comment.author?.type === 'guest'}
				<span class="rounded-full bg-paper px-1.5 py-0.5 text-[0.65rem] text-ink-faint">
					{t('feed.author.guest')}
				</span>
			{/if}
			<RelativeTime datetime={comment.inserted_at} class="text-xs" />
			{#if comment.edited_at}
				<span class="text-xs text-ink-faint">· {t('feed.edited')}</span>
			{/if}
			{#if comment.pending_approval}
				<span class="text-xs text-accent">· {t('feed.comment.pending')}</span>
			{/if}
		</div>

		{#if comment.deleted}
			<p class="mt-0.5 text-sm text-ink-faint italic">{t('feed.comment.removed')}</p>
		{:else if editing}
			<div class="mt-1.5">
				<CommentComposer
					id="edit-comment-{comment.id}"
					initialValue={comment.body_markdown ?? ''}
					submitLabel={t('common.save')}
					compact
					onSubmit={saveEdit}
					onCancel={() => (editing = false)}
				/>
			</div>
		{:else}
			<Markdown source={comment.body_markdown} inline class="mt-0.5 text-sm text-ink" />

			<div class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1">
				<ReactionBar subject={comment} onToggle={onReact} idPrefix="comment-{comment.id}" />
				<div class="flex items-center gap-3 text-xs text-ink-faint">
					{#if onReply && !isReply}
						<button
							type="button"
							class="hover:text-ink-muted"
							onclick={() => (replying = !replying)}
						>
							{t('feed.comment.reply')}
						</button>
					{/if}
					{#if isMine}
						<button type="button" class="hover:text-ink-muted" onclick={() => (editing = true)}>
							{t('common.edit')}
						</button>
						<button type="button" class="hover:text-danger" onclick={onDelete}>
							{t('common.delete')}
						</button>
					{/if}
					{#if onReport}
						<button
							type="button"
							class="hover:text-ink-muted"
							onclick={() => (reporting = !reporting)}
						>
							{t('feed.report.action')}
						</button>
					{/if}
				</div>
			</div>

			{#if reporting && onReport}
				<div class="mt-2 flex flex-col gap-2 rounded-lg border border-line bg-paper px-3 py-2.5">
					<p class="text-sm font-medium text-ink">{t('feed.report.title')}</p>
					<CommentComposer
						id="report-comment-{comment.id}"
						placeholder={t('feed.report.placeholder')}
						submitLabel={t('feed.report.send')}
						compact
						onSubmit={sendReport}
						onCancel={() => (reporting = false)}
					/>
				</div>
			{:else if reported}
				<p class="mt-1.5 text-sm text-accent" role="status">{t('feed.report.thanks')}</p>
			{/if}

			{#if replying && onReply}
				<div class="mt-2">
					<CommentComposer
						id="reply-{comment.id}"
						placeholder={t('feed.comment.replyPlaceholder')}
						submitLabel={t('feed.comment.reply')}
						compact
						onSubmit={sendReply}
						onCancel={() => (replying = false)}
					/>
				</div>
			{/if}
		{/if}
	</div>
</div>
