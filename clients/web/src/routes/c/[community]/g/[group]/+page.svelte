<script lang="ts">
	import { onMount } from 'svelte';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { fetchPublicGroup, fetchPublicGroupPosts, type Group } from '$lib/public/api.js';
	import type { Post } from '$lib/feed/types.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import Avatar from '$lib/ui/Avatar.svelte';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';
	import RelativeTime from '$lib/ui/RelativeTime.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// The tokenless public group page (issue #185 slice B): the group's
	// public face plus its feed, cursor-paginated the same way the
	// authenticated feed is — the content a guest browses before deciding
	// whether to comment (via the request form on each post's own page).
	let loadState = $state<'loading' | 'ready' | 'error'>('loading');
	let group = $state<Group | null>(null);
	let posts = $state<Post[]>([]);
	let nextCursor = $state<string | null>(null);
	let loadingMore = $state(false);

	const communitySlug = $derived(page.params.community!);
	const groupSlug = $derived(page.params.group!);

	onMount(async () => {
		try {
			const [fetchedGroup, firstPage] = await Promise.all([
				fetchPublicGroup(window.location.origin, communitySlug, groupSlug),
				fetchPublicGroupPosts(window.location.origin, communitySlug, groupSlug)
			]);
			group = fetchedGroup;
			posts = firstPage.posts;
			nextCursor = firstPage.nextCursor;
			loadState = 'ready';
		} catch {
			loadState = 'error';
		}
	});

	async function loadMore(): Promise<void> {
		if (!nextCursor || loadingMore) return;
		loadingMore = true;
		try {
			const nextPage = await fetchPublicGroupPosts(
				window.location.origin,
				communitySlug,
				groupSlug,
				nextCursor
			);
			posts = [...posts, ...nextPage.posts];
			nextCursor = nextPage.nextCursor;
		} catch {
			// Leave `nextCursor` untouched: the button re-enables and the
			// same page can simply be retried — no error state needed for
			// an optional load-more.
		} finally {
			loadingMore = false;
		}
	}

	function postHref(postId: string): string {
		return resolve(`/c/${communitySlug}/g/${groupSlug}/p/${postId}`);
	}
</script>

<svelte:head>
	<title>{group ? group.name : t('public.group.loading')} · {t('app.name')}</title>
</svelte:head>

<PublicShell maxWidth="max-w-2xl">
	{#if loadState === 'loading'}
		<div aria-busy="true" aria-live="polite">
			<p class="text-center text-sm text-ink-muted">{t('public.group.loading')}</p>
			<div class="mt-6 flex flex-col gap-3">
				<Skeleton class="h-6 w-2/3" />
				<Skeleton class="h-24 w-full" />
				<Skeleton class="h-24 w-full" />
			</div>
		</div>
	{:else if loadState === 'error' || !group}
		<EmptyState title={t('public.group.error.title')} body={t('public.group.error.body')} />
	{:else}
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a
			href={resolve(`/c/${communitySlug}`)}
			class="text-sm text-ink-muted underline decoration-line underline-offset-4 transition-colors duration-150 hover:text-ink"
		>
			{t('public.group.backToCommunity')}
		</a>
		<h1 class="mt-2 text-xl font-semibold tracking-tight text-ink">{group.name}</h1>
		{#if group.description}
			<p class="mt-1 text-sm text-ink-muted">{group.description}</p>
		{/if}

		{#if posts.length === 0}
			<p class="mt-8 text-sm text-ink-muted">{t('public.group.posts.empty')}</p>
		{:else}
			<div class="mt-8 flex flex-col gap-3">
				{#each posts as post (post.id)}
					<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
					<a href={postHref(post.id)} class="block">
						<Card class="p-4 transition-colors duration-150 hover:border-ink-faint/60 sm:p-5">
							<div class="flex items-start gap-3">
								<Avatar author={post.author} size="sm" />
								<div class="min-w-0 flex-1">
									<div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
										<span class="text-sm font-medium text-ink">
											{post.author?.display_name ?? t('feed.author.unknown')}
										</span>
										<RelativeTime datetime={post.published_at} class="text-xs" />
									</div>
									{#if post.body_markdown}
										<p class="mt-1 line-clamp-3 text-sm text-ink-muted">{post.body_markdown}</p>
									{/if}
									{#if post.comment_count}
										<p class="mt-2 text-xs text-ink-faint">
											{t('feed.comment.count', { count: String(post.comment_count) })}
										</p>
									{/if}
								</div>
							</div>
						</Card>
					</a>
				{/each}
			</div>

			{#if nextCursor}
				<div class="mt-4 flex justify-center">
					<Button
						id="public-group-load-more"
						variant="secondary"
						onclick={loadMore}
						disabled={loadingMore}
					>
						{loadingMore ? t('common.loading') : t('public.group.posts.loadMore')}
					</Button>
				</div>
			{/if}
		{/if}
	{/if}
</PublicShell>
