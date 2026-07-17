<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { createHomeStore } from '$lib/home/home-store.svelte.js';
	import ActivityItem from '$lib/home/components/ActivityItem.svelte';
	import EventItem from '$lib/home/components/EventItem.svelte';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { reconnectInstance } from '$lib/realtime/registry.svelte.js';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import FailedInstancesBanner from '$lib/ui/FailedInstancesBanner.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';
	import StaleBanner from '$lib/ui/StaleBanner.svelte';
	import TabIcon from '$lib/ui/TabIcon.svelte';

	const home = createHomeStore();

	// Load (and go live) whenever the set of added instances changes; the store
	// re-fetches every instance's /home in parallel and re-wires channels.
	$effect(() => {
		const list = instances.list;
		home.load(list);
		return () => home.stop();
	});
</script>

<svelte:head><title>{t('nav.home')} · {t('app.name')}</title></svelte:head>

<h1 class="mb-5 text-xl font-semibold tracking-tight text-ink">{t('home.title')}</h1>

{#if home.snapshotSavedAt}
	<StaleBanner savedAt={home.snapshotSavedAt} />
{/if}

<FailedInstancesBanner
	failures={home.failedInstances}
	onRetry={(failure) => {
		reconnectInstance(failure.instance);
		home.load(instances.list);
	}}
/>

{#if home.loadState === 'loading' && home.allBuckets.length === 0}
	<div class="flex flex-col gap-4">
		{#each [0, 1, 2] as skeleton (skeleton)}
			<div class="flex items-center gap-3 rounded-xl border border-line bg-surface p-3.5">
				<Skeleton class="size-8 rounded-full" />
				<div class="flex flex-1 flex-col gap-2">
					<Skeleton class="h-3.5 w-40" />
					<Skeleton class="h-3.5 w-3/4" />
				</div>
			</div>
		{/each}
	</div>
{:else if home.isEmpty}
	<EmptyState title={t('home.empty.title')} body={t('home.empty.body')}>
		{#snippet icon()}<TabIcon name="home" class="size-8" />{/snippet}
	</EmptyState>
{:else}
	<!-- Community-first filter chips (ADR 0024): a merged view plus one-tap
	     narrowing to a single community. -->
	{#if home.allBuckets.length > 1}
		<div class="mb-5 flex flex-wrap gap-2" role="group" aria-label={t('home.filter.label')}>
			<button
				type="button"
				onclick={() => home.setFilter(null)}
				aria-pressed={home.activeFilter === null}
				class="rounded-full border px-3 py-1 text-sm transition-colors duration-150 {home.activeFilter ===
				null
					? 'border-accent/40 bg-accent/10 text-accent'
					: 'border-line bg-surface text-ink-muted hover:border-ink-faint/60'}"
			>
				{t('home.filter.all')}
			</button>
			{#each home.allBuckets as bucket (bucket.key.id)}
				<button
					type="button"
					onclick={() => home.setFilter(bucket.key.id)}
					aria-pressed={home.activeFilter === bucket.key.id}
					class="rounded-full border px-3 py-1 text-sm transition-colors duration-150 {home.activeFilter ===
					bucket.key.id
						? 'border-accent/40 bg-accent/10 text-accent'
						: 'border-line bg-surface text-ink-muted hover:border-ink-faint/60'}"
				>
					{bucket.key.communityName}
				</button>
			{/each}
		</div>
	{/if}

	<div class="flex flex-col gap-8">
		{#each home.buckets as bucket (bucket.key.id)}
			<section class="flex flex-col gap-3">
				<div class="flex items-baseline gap-2">
					<h2 class="text-base font-semibold text-ink">{bucket.key.communityName}</h2>
					<!-- Instance provenance is disambiguation, so it needs both several
					     sources (#322: never with a single account) and several buckets. -->
					{#if instances.several && home.allBuckets.length > 1}
						<span class="text-xs text-ink-faint">{bucket.key.instanceName}</span>
					{/if}
				</div>

				{#if bucket.events.length > 0}
					<div class="flex flex-col gap-2">
						<h3 class="text-xs font-medium tracking-wide text-ink-faint uppercase">
							{t('home.upcoming')}
						</h3>
						{#each bucket.events as event (event.id)}
							<EventItem {event} />
						{/each}
					</div>
				{/if}

				{#if bucket.posts.length > 0}
					<div class="flex flex-col gap-2">
						{#if bucket.events.length > 0}
							<h3 class="text-xs font-medium tracking-wide text-ink-faint uppercase">
								{t('home.recent')}
							</h3>
						{/if}
						{#each bucket.posts as post (post.id)}
							<ActivityItem {post} />
						{/each}
					</div>
				{/if}
			</section>
		{/each}
	</div>
{/if}
