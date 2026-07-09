<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import {
		FeedApiError,
		fetchCommunity,
		fetchGroup,
		type FeedErrorKind,
		type Group
	} from '$lib/feed/api.js';
	import { createFeedStore, type FeedStore } from '$lib/feed/feed-store.svelte.js';
	import Composer from '$lib/feed/components/Composer.svelte';
	import PostCard from '$lib/feed/components/PostCard.svelte';
	import type { Community } from '$lib/feed/types.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { socketStatus } from '$lib/realtime/registry.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';
	import TabIcon from '$lib/ui/TabIcon.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let store = $state<FeedStore | null>(null);
	let community = $state<Community | null>(null);
	let group = $state<Group | null>(null);
	let metaError = $state<FeedErrorKind | null>(null);

	const ref = $derived({ community: page.params.community!, group: page.params.group! });
	const status = $derived(instance ? socketStatus(instance.id) : 'idle');

	// Resolve community + group metadata (names, group id for the channel topic),
	// build the feed store, load the first page, and go live. Re-runs when the
	// instance or the route params change; the cleanup stops the previous feed's
	// live subscription so navigating between groups doesn't leak channels.
	$effect(() => {
		const inst = instance;
		const communitySlug = page.params.community;
		const groupSlug = page.params.group;
		if (!inst || !communitySlug || !groupSlug) return;

		let cancelled = false;
		let localStore: FeedStore | null = null;
		store = null;
		community = null;
		group = null;
		metaError = null;

		(async () => {
			try {
				const [resolvedCommunity, resolvedGroup] = await Promise.all([
					fetchCommunity(inst, communitySlug),
					fetchGroup(inst, communitySlug, groupSlug)
				]);
				if (cancelled) return;
				community = resolvedCommunity;
				group = resolvedGroup;
				localStore = createFeedStore(
					inst,
					{ community: communitySlug, group: groupSlug },
					resolvedGroup.id
				);
				store = localStore;
				await localStore.load();
				if (!cancelled) localStore.startLive();
			} catch (error) {
				if (!cancelled) metaError = error instanceof FeedApiError ? error.kind : 'server';
			}
		})();

		return () => {
			cancelled = true;
			localStore?.stop();
		};
	});

	const homeHref = resolve('/');
</script>

<svelte:head>
	<title>{group?.name ?? t('nav.groups')} · {t('app.name')}</title>
</svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')}>
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={homeHref} class="text-sm text-accent hover:underline">{t('feed.backHome')}</a>
	</EmptyState>
{:else if metaError}
	<EmptyState
		title={metaError === 'auth' ? t('feed.error.authTitle') : t('feed.error.title')}
		body={metaError === 'auth' ? t('feed.error.authBody') : t('feed.error.body')}
	/>
{:else}
	<header class="mb-5 flex flex-col gap-3">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={homeHref} class="flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
				<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
			</svg>
			{community?.name ?? t('common.back')}
		</a>
		<div class="flex items-end justify-between gap-3">
			<div class="min-w-0">
				<h1 class="truncate text-xl font-semibold tracking-tight text-ink">
					{group?.name ?? ''}
				</h1>
				{#if group?.description}
					<p class="mt-0.5 line-clamp-2 text-sm text-ink-muted">{group.description}</p>
				{/if}
			</div>
			{#if store}
				<div
					class="flex shrink-0 overflow-hidden rounded-lg border border-line"
					role="group"
					aria-label={t('feed.sort.label')}
				>
					{#each [['chronological', t('feed.sort.latest')], ['activity', t('feed.sort.active')]] as const as [value, label] (value)}
						<button
							type="button"
							onclick={() => store?.setSort(value)}
							aria-pressed={store.sort === value}
							class="px-3 py-1.5 text-xs transition-colors duration-150 {store.sort === value
								? 'bg-ink/5 font-medium text-ink'
								: 'text-ink-muted hover:bg-ink/5'}"
						>
							{label}
						</button>
					{/each}
				</div>
			{/if}
		</div>

		{#if status === 'unauthorized'}
			<p class="rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger">
				{t('feed.reauth')}
			</p>
		{:else if status === 'reconnecting'}
			<p class="text-xs text-ink-faint">{t('feed.reconnecting')}</p>
		{/if}
	</header>

	{#if store}
		<div class="mb-5">
			<Composer {store} {instance} {ref} />
		</div>

		{#if store.actionError}
			<div
				class="mb-4 flex items-center justify-between gap-3 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
				role="alert"
			>
				<span>{store.actionError.message}</span>
				<button
					type="button"
					class="shrink-0 text-danger/70 hover:text-danger"
					aria-label={t('common.dismiss')}
					onclick={() => store?.clearActionError()}
				>
					✕
				</button>
			</div>
		{/if}

		{#if store.loadState === 'loading'}
			<div class="flex flex-col gap-4">
				{#each [0, 1, 2] as skeleton (skeleton)}
					<div class="flex flex-col gap-3 rounded-xl border border-line bg-surface p-5">
						<div class="flex items-center gap-3">
							<Skeleton class="size-10 rounded-full" />
							<Skeleton class="h-4 w-32" />
						</div>
						<Skeleton class="h-4 w-full" />
						<Skeleton class="h-4 w-4/5" />
					</div>
				{/each}
			</div>
		{:else if store.loadState === 'error'}
			<EmptyState
				title={store.loadErrorKind === 'auth' ? t('feed.error.authTitle') : t('feed.error.title')}
				body={store.loadErrorKind === 'auth' ? t('feed.error.authBody') : t('feed.error.body')}
			>
				<Button variant="secondary" size="sm" onclick={() => store?.load()}>
					{t('common.retry')}
				</Button>
			</EmptyState>
		{:else if store.items.length === 0}
			<EmptyState title={t('feed.empty.title')} body={t('feed.empty.body')}>
				{#snippet icon()}<TabIcon name="groups" class="size-8" />{/snippet}
			</EmptyState>
		{:else}
			<div class="flex flex-col gap-4">
				{#each store.items as post (post.id)}
					<PostCard {post} {store} {instance} currentUserId={instance.user.id} />
				{/each}
			</div>

			{#if store.hasMore}
				<div class="mt-6 flex justify-center">
					<Button
						variant="secondary"
						onclick={() => store?.loadMore()}
						disabled={store.loadingMore}
					>
						{store.loadingMore ? t('common.loading') : t('feed.loadMore')}
					</Button>
				</div>
			{/if}
		{/if}
	{/if}
{/if}
