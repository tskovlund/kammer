<script lang="ts">
	import { resolve } from '$app/paths';
	import type { MergedPost } from '$lib/instances/home.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import Avatar from '$lib/ui/Avatar.svelte';
	import RelativeTime from '$lib/ui/RelativeTime.svelte';

	interface Props {
		post: MergedPost;
	}

	let { post }: Props = $props();

	// Home shows a calm preview; the full post (with its interactions) lives in
	// the group feed this links into.
	const href = $derived(
		resolve(`/i/${post.instance.id}/c/${post.community.slug}/g/${post.group.slug}`)
	);

	// A short plain-text snippet — strip Markdown syntax rather than render it,
	// so the preview stays quiet and single-line-ish.
	const snippet = $derived(
		(post.body_markdown ?? '')
			.replace(/[#*_`>~[\]()!-]/g, '')
			.replace(/\s+/g, ' ')
			.trim()
			.slice(0, 160)
	);

	const reactionTotal = $derived(Object.values(post.reactions).reduce((sum, n) => sum + n, 0));
	const commentCount = $derived(post.comment_count ?? 0);
</script>

<!-- eslint-disable svelte/no-navigation-without-resolve -->
<a
	{href}
	class="flex gap-3 rounded-xl border border-line bg-surface p-3.5 transition-colors duration-150 hover:border-ink-faint/50"
>
	<Avatar author={post.author} size="sm" />
	<div class="min-w-0 flex-1">
		<div class="flex flex-wrap items-baseline gap-x-2 text-sm">
			<span class="font-medium text-ink"
				>{post.author?.display_name ?? t('feed.author.unknown')}</span
			>
			<span class="text-ink-faint">·</span>
			<span class="truncate text-ink-muted">{post.group.name}</span>
			<RelativeTime datetime={post.published_at} class="text-xs" />
		</div>
		{#if snippet}
			<p class="mt-0.5 line-clamp-2 text-sm text-ink-muted">{snippet}</p>
		{:else if post.attachments.length > 0}
			<p class="mt-0.5 text-sm text-ink-faint italic">{t('home.attachmentOnly')}</p>
		{:else if post.poll}
			<p class="mt-0.5 text-sm text-ink-faint italic">{t('home.pollPost')}</p>
		{/if}
		{#if reactionTotal > 0 || commentCount > 0 || post.acknowledgment_required}
			<div class="mt-1.5 flex flex-wrap items-center gap-3 text-xs text-ink-faint">
				{#if post.pinned}<span class="text-accent">{t('feed.pinned')}</span>{/if}
				{#if reactionTotal > 0}<span>{t('home.reactions', { count: String(reactionTotal) })}</span
					>{/if}
				{#if commentCount > 0}<span>{t('feed.comment.count', { count: String(commentCount) })}</span
					>{/if}
				{#if post.acknowledgment_required && !post.my_acknowledged}
					<span class="text-accent">{t('feed.ack.required')}</span>
				{/if}
			</div>
		{/if}
	</div>
</a>
<!-- eslint-enable svelte/no-navigation-without-resolve -->
