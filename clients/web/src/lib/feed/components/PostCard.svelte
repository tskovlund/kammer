<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import type { FeedStore } from '$lib/feed/feed-store.svelte.js';
	import type { Post } from '$lib/feed/types.js';
	import type { Instance } from '$lib/instances/types.js';
	import Avatar from '$lib/ui/Avatar.svelte';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import Chip from '$lib/ui/Chip.svelte';
	import Markdown from '$lib/ui/Markdown.svelte';
	import RelativeTime from '$lib/ui/RelativeTime.svelte';
	import Attachments from './Attachments.svelte';
	import CommentComposer from './CommentComposer.svelte';
	import CommentThread from './CommentThread.svelte';
	import PollView from './PollView.svelte';
	import ReactionBar from './ReactionBar.svelte';

	interface Props {
		post: Post;
		store: FeedStore;
		instance: Instance;
		currentUserId: string;
		/** Community provenance chip, shown on the merged Home / cross-group views. */
		provenance?: string;
	}

	let { post, store, instance, currentUserId, provenance }: Props = $props();

	const isMine = $derived(post.author?.type === 'user' && post.author.id === currentUserId);
	const scheduled = $derived(!post.deleted && new Date(post.published_at).getTime() > Date.now());
	const commentCount = $derived(post.comment_count ?? post.comments?.length ?? 0);

	let showComments = $state(false);
	let menuOpen = $state(false);
	let editing = $state(false);

	async function saveEdit(body: string): Promise<boolean> {
		const ok = await store.editPost(post.id, body);
		if (ok) editing = false;
		return ok;
	}
</script>

<Card class="p-4 sm:p-5">
	<article class="flex flex-col gap-3">
		<header class="flex items-start gap-3">
			<Avatar author={post.author} />
			<div class="min-w-0 flex-1">
				<div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
					<span class="font-medium text-ink">
						{post.author?.display_name ?? t('feed.author.unknown')}
					</span>
					<RelativeTime datetime={post.published_at} class="text-xs" />
					{#if post.edited_at}
						<span class="text-xs text-ink-faint">· {t('feed.edited')}</span>
					{/if}
				</div>
				{#if provenance}
					<div class="mt-1">
						<Chip tone="accent">{provenance}</Chip>
					</div>
				{/if}
			</div>

			<div class="flex items-center gap-1.5">
				{#if post.pinned}
					<span class="flex items-center gap-1 text-xs text-accent" title={t('feed.pinned')}>
						<svg viewBox="0 0 24 24" fill="currentColor" class="size-3.5" aria-hidden="true">
							<path d="M16 3l5 5-4 1-3 3 1 5-2 2-4-4-5 5-1-1 5-5-4-4 2-2 5 1 3-3z" />
						</svg>
						<span class="sr-only sm:not-sr-only">{t('feed.pinned')}</span>
					</span>
				{/if}

				<div class="relative">
					<button
						type="button"
						onclick={() => (menuOpen = !menuOpen)}
						aria-expanded={menuOpen}
						aria-haspopup="true"
						aria-label={t('feed.postMenu')}
						class="flex size-8 items-center justify-center rounded-lg text-ink-faint transition-colors hover:bg-ink/5 hover:text-ink-muted"
					>
						<svg viewBox="0 0 24 24" fill="currentColor" class="size-5" aria-hidden="true">
							<path
								d="M12 6.75a1.25 1.25 0 100-2.5 1.25 1.25 0 000 2.5zm0 6.5a1.25 1.25 0 100-2.5 1.25 1.25 0 000 2.5zm0 6.5a1.25 1.25 0 100-2.5 1.25 1.25 0 000 2.5z"
							/>
						</svg>
					</button>
					{#if menuOpen}
						<div
							role="menu"
							class="absolute top-full right-0 z-10 mt-1 flex w-44 flex-col overflow-hidden rounded-lg border border-line bg-surface py-1 text-sm shadow-sm"
						>
							{#if isMine && !post.deleted}
								<button
									type="button"
									role="menuitem"
									class="px-3 py-2 text-left text-ink hover:bg-ink/5"
									onclick={() => {
										editing = true;
										menuOpen = false;
									}}
								>
									{t('common.edit')}
								</button>
							{/if}
							<!-- Pin is a moderator action; the API authorizes it, and a
							     non-moderator gets a friendly forbidden message. -->
							<button
								type="button"
								role="menuitem"
								class="px-3 py-2 text-left text-ink hover:bg-ink/5"
								onclick={() => {
									store.setPinned(post.id, !post.pinned);
									menuOpen = false;
								}}
							>
								{post.pinned ? t('feed.unpin') : t('feed.pin')}
							</button>
							{#if isMine && !post.deleted}
								<button
									type="button"
									role="menuitem"
									class="px-3 py-2 text-left text-danger hover:bg-danger/5"
									onclick={() => {
										store.deletePost(post.id);
										menuOpen = false;
									}}
								>
									{t('common.delete')}
								</button>
							{/if}
						</div>
					{/if}
				</div>
			</div>
		</header>

		{#if scheduled || post.pending_approval}
			<div class="flex flex-wrap gap-1.5">
				{#if scheduled}
					<Chip>{t('feed.scheduled', { at: new Date(post.published_at).toLocaleString() })}</Chip>
				{/if}
				{#if post.pending_approval}
					<Chip>{t('feed.pendingApproval')}</Chip>
				{/if}
			</div>
		{/if}

		{#if post.deleted}
			<p class="text-sm text-ink-faint italic">{t('feed.post.removed')}</p>
		{:else if editing}
			<CommentComposer
				id="edit-post-{post.id}"
				initialValue={post.body_markdown ?? ''}
				submitLabel={t('common.save')}
				onSubmit={saveEdit}
				onCancel={() => (editing = false)}
			/>
		{:else}
			{#if post.body_markdown}
				<Markdown source={post.body_markdown} class="text-[0.95rem] text-ink" />
			{/if}

			{#if post.attachments.length > 0}
				<Attachments {instance} attachments={post.attachments} />
			{/if}

			{#if post.poll}
				<PollView
					poll={post.poll}
					idPrefix="post-{post.id}"
					onVote={(optionIds) => store.vote(post.id, optionIds)}
				/>
			{/if}

			{#if post.acknowledgment_required}
				<div
					class="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-accent/25 bg-accent/5 px-3 py-2"
				>
					<div class="flex items-center gap-2 text-sm">
						<span class="font-medium text-accent">{t('feed.ack.required')}</span>
						<span class="text-ink-faint">
							{t('feed.ack.count', { count: String(post.acknowledged_count) })}
						</span>
					</div>
					{#if post.my_acknowledged}
						<span class="flex items-center gap-1.5 text-sm font-medium text-accent">
							<svg viewBox="0 0 20 20" fill="currentColor" class="size-4" aria-hidden="true">
								<path
									fill-rule="evenodd"
									d="M16.7 5.3a1 1 0 010 1.4l-7.5 7.5a1 1 0 01-1.4 0l-3.5-3.5a1 1 0 011.4-1.4l2.8 2.8 6.8-6.8a1 1 0 011.4 0z"
									clip-rule="evenodd"
								/>
							</svg>
							{t('feed.ack.done')}
						</span>
					{:else}
						<Button variant="primary" size="sm" onclick={() => store.acknowledge(post.id)}>
							{t('feed.ack.button')}
						</Button>
					{/if}
				</div>
			{/if}

			<footer class="flex flex-wrap items-center justify-between gap-3 pt-1">
				<ReactionBar
					subject={post}
					idPrefix="post-{post.id}"
					onToggle={(emoji) => store.react(post.id, emoji)}
				/>
				<button
					type="button"
					onclick={() => (showComments = !showComments)}
					aria-expanded={showComments}
					class="flex items-center gap-1.5 text-sm text-ink-muted transition-colors hover:text-ink"
				>
					<svg
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="1.5"
						class="size-4"
						aria-hidden="true"
					>
						<path
							stroke-linecap="round"
							stroke-linejoin="round"
							d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.8 9.8 0 01-4-.85L3 20l1.35-3.5A7.6 7.6 0 013 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"
						/>
					</svg>
					{commentCount > 0
						? t('feed.comment.count', { count: String(commentCount) })
						: t('feed.comment.add')}
				</button>
			</footer>
		{/if}

		{#if showComments && !post.deleted}
			<CommentThread {post} {store} {currentUserId} />
		{/if}
	</article>
</Card>
