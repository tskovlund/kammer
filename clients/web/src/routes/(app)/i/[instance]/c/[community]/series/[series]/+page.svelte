<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import AttendanceMatrix from '$lib/events/components/AttendanceMatrix.svelte';
	import { createSeriesStore, type SeriesStore } from '$lib/events/series-store.svelte.js';
	import type { SeriesOccurrence } from '$lib/events/types.js';
	import { formatDate, formatDateTime } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import ErrorBanner from '$lib/ui/ErrorBanner.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	const communitySlug = $derived(page.params.community!);

	let store = $state<SeriesStore | null>(null);

	$effect(() => {
		const inst = instance;
		const community = page.params.community;
		const id = page.params.series;
		if (!inst || !community || !id) return;

		const localStore = createSeriesStore(inst, community, id);
		store = localStore;
		void localStore.load();
	});

	const detail = $derived(store?.detail ?? null);
	const eventsHref = resolve('/events');

	const seriesSummary = $derived(
		detail
			? `${t(`events.series.frequency.${detail.series.frequency}`)} · ${t('events.series.until', {
					date: formatDate(detail.series.until, i18n.locale)
				})}`
			: ''
	);

	function occurrenceHref(occurrenceId: string): string {
		return resolve(`/i/${page.params.instance}/c/${communitySlug}/e/${occurrenceId}`);
	}

	function occurrenceWhen(occurrence: SeriesOccurrence): string {
		return occurrence.all_day
			? formatDate(occurrence.starts_at, i18n.locale)
			: formatDateTime(occurrence.starts_at, i18n.locale);
	}
</script>

<svelte:head><title>{t('events.series.title')} · {t('app.name')}</title></svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')}>
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={eventsHref} class="text-sm text-accent hover:underline">{t('common.back')}</a>
	</EmptyState>
{:else}
	<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
	<a href={eventsHref} class="mb-4 flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
		<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
			<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
		</svg>
		{t('nav.events')}
	</a>

	{#if !store || store.loadState === 'loading'}
		<div class="flex flex-col gap-4">
			<Skeleton class="h-7 w-1/2" />
			<Skeleton class="h-4 w-1/3" />
			<Skeleton class="h-24 w-full" />
		</div>
	{:else if store.loadState === 'error' || !detail}
		{#if store?.loadErrorKind === 'forbidden'}
			<EmptyState
				title={t('events.series.forbidden.title')}
				body={t('events.series.forbidden.body')}
			/>
		{:else if store?.loadErrorKind === 'not_found'}
			<EmptyState
				title={t('events.series.notFound.title')}
				body={t('events.series.notFound.body')}
			/>
		{:else}
			<EmptyState
				title={store?.loadErrorKind === 'auth' ? t('feed.error.authTitle') : t('feed.error.title')}
				body={store?.loadErrorKind === 'auth' ? t('feed.error.authBody') : t('feed.error.body')}
			>
				<Button variant="secondary" size="sm" onclick={() => store?.load()}>
					{t('common.retry')}
				</Button>
			</EmptyState>
		{/if}
	{:else}
		<article class="flex flex-col gap-6">
			<header class="flex flex-col gap-1">
				<h1 class="text-2xl font-semibold tracking-tight text-ink">{t('events.series.title')}</h1>
				<p class="text-sm text-ink-muted">{seriesSummary}</p>
			</header>

			{#if store?.actionError}
				<ErrorBanner kind={store.actionError} ondismiss={() => store?.clearActionError()} />
			{/if}

			<section class="flex flex-col gap-2">
				<h2 class="text-xs font-semibold tracking-wide text-ink-faint uppercase">
					{t('events.series.occurrences')}
				</h2>
				<ul class="flex flex-col divide-y divide-line">
					{#each detail.occurrences as occurrence (occurrence.id)}
						<li class="flex flex-wrap items-center justify-between gap-3 py-2.5">
							<div class="flex min-w-0 flex-col">
								<!-- eslint-disable svelte/no-navigation-without-resolve -->
								<a
									href={occurrenceHref(occurrence.id)}
									class={[
										'text-sm font-medium hover:underline',
										occurrence.cancelled ? 'text-ink-faint line-through' : 'text-accent'
									]}
								>
									{occurrenceWhen(occurrence)}
								</a>
								<!-- eslint-enable svelte/no-navigation-without-resolve -->

								<span class="text-xs text-ink-muted">
									{#if occurrence.cancelled}
										{t('events.series.cancelledBadge')}
									{:else}
										{t('events.series.rsvpSummary', {
											yes: String(occurrence.rsvp_counts.yes),
											maybe: String(occurrence.rsvp_counts.maybe)
										})}
									{/if}
								</span>
							</div>
							<Button
								variant="secondary"
								size="sm"
								disabled={store?.busy}
								onclick={() => store?.toggleCancelled(occurrence.id, !occurrence.cancelled)}
							>
								{occurrence.cancelled ? t('events.series.restore') : t('events.series.cancel')}
							</Button>
						</li>
					{/each}
				</ul>
			</section>

			<section class="flex flex-col gap-2">
				<h2 class="text-xs font-semibold tracking-wide text-ink-faint uppercase">
					{t('events.series.attendance')}
				</h2>
				<AttendanceMatrix attendance={detail.attendance} />
			</section>
		</article>
	{/if}
{/if}
