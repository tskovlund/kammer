<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import type { Comment } from '$lib/feed/types.js';
	import Avatar from '$lib/ui/Avatar.svelte';
	import Markdown from '$lib/ui/Markdown.svelte';
	import RelativeTime from '$lib/ui/RelativeTime.svelte';

	/**
	 * Read-only comment thread for anonymous public visitors (issue #185
	 * slice B) — no reactions, edit, delete, or reply, since none of those
	 * are guest capabilities. Flat, not nested: a reply gets a subtle left
	 * border rather than full indentation logic, since threading UI adds
	 * complexity a read-only guest view doesn't need.
	 */
	interface Props {
		comments: Comment[];
		emptyLabel: string;
	}

	let { comments, emptyLabel }: Props = $props();
</script>

{#if comments.length === 0}
	<p class="text-sm text-ink-muted">{emptyLabel}</p>
{:else}
	<ul class="flex flex-col gap-4">
		{#each comments as comment (comment.id)}
			<li class={comment.parent_comment_id ? 'ml-6 border-l border-line pl-3' : ''}>
				<div class="flex gap-2.5">
					<Avatar author={comment.author} size="sm" />
					<div class="min-w-0 flex-1">
						<div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5 text-sm">
							<span class="font-medium text-ink">
								{comment.author?.display_name ?? t('feed.author.unknown')}
							</span>
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
						{:else}
							<Markdown source={comment.body_markdown} inline class="mt-0.5 text-sm text-ink" />
						{/if}
					</div>
				</div>
			</li>
		{/each}
	</ul>
{/if}
