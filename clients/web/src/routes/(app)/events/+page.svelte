<script lang="ts">
	import { resolve } from '$app/paths';
	import { dayOffsetFromToday } from '$lib/events/agenda.js';
	import { createEventsStore } from '$lib/events/events-store.svelte.js';
	import type { MergedEvent } from '$lib/events/types.js';
	import { formatDate, formatTime } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';
	import StaleBanner from '$lib/ui/StaleBanner.svelte';
	import TabIcon from '$lib/ui/TabIcon.svelte';

	const events = createEventsStore();

	$effect(() => {
		const list = instances.list;
		events.load(list);
		return () => events.stop();
	});

	function dayLabel(day: { key: string; date: Date }): string {
		const offset = dayOffsetFromToday(day.key);
		if (offset === 0) return t('events.today');
		if (offset === 1) return t('events.tomorrow');
		return formatDate(day.date.toISOString(), i18n.locale);
	}

	function eventHref(event: MergedEvent): string {
		return resolve(`/i/${event.instance.id}/c/${event.community.slug}/e/${event.id}`);
	}

	function dayNumber(iso: string): string {
		return String(new Date(iso).getDate());
	}
</script>

<svelte:head><title>{t('nav.events')} · {t('app.name')}</title></svelte:head>

<div class="mb-5 flex items-center justify-between gap-3">
	<h1 class="text-xl font-semibold tracking-tight text-ink">{t('nav.events')}</h1>
	<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
	<a
		href={resolve('/events/new')}
		class="inline-flex items-center gap-1.5 rounded-lg border border-line bg-surface px-3 py-1.5 text-sm font-medium text-ink transition-colors duration-150 hover:border-ink-faint/60"
	>
		<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
			<path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
		</svg>
		{t('events.new')}
	</a>
</div>

{#if events.snapshotSavedAt}
	<StaleBanner savedAt={events.snapshotSavedAt} />
{/if}

{#if events.failedInstances.length > 0}
	<div class="mb-5 flex flex-col gap-2">
		{#each events.failedInstances as failure (failure.instance.id)}
			<div
				class="rounded-lg border border-danger/25 bg-danger/5 px-3 py-2 text-sm text-ink-muted"
				role="status"
			>
				{#if failure.kind === 'auth'}
					{t('home.failed.auth', { name: failure.instance.instanceName })}
				{:else if failure.kind === 'network'}
					{t('home.failed.network', { name: failure.instance.instanceName })}
				{:else}
					{t('home.failed.server', { name: failure.instance.instanceName })}
				{/if}
			</div>
		{/each}
	</div>
{/if}

{#if events.loadState === 'loading' && events.isEmpty}
	<div class="flex flex-col gap-3">
		{#each [0, 1, 2] as skeleton (skeleton)}
			<div class="flex items-center gap-3 rounded-xl border border-line bg-surface p-3.5">
				<Skeleton class="size-11 rounded-lg" />
				<div class="flex flex-1 flex-col gap-2">
					<Skeleton class="h-3.5 w-40" />
					<Skeleton class="h-3.5 w-2/3" />
				</div>
			</div>
		{/each}
	</div>
{:else if events.loadState === 'error'}
	<EmptyState title={t('feed.error.title')} body={t('feed.error.body')} />
{:else if events.isEmpty}
	<EmptyState title={t('events.empty.title')} body={t('events.empty.body')}>
		{#snippet icon()}<TabIcon name="events" class="size-8" />{/snippet}
	</EmptyState>
{:else}
	<!-- Community-first filter chips (ADR 0024). -->
	{#if events.chips.length > 1}
		<div class="mb-5 flex flex-wrap gap-2" role="group" aria-label={t('home.filter.label')}>
			<button
				type="button"
				onclick={() => events.setFilter(null)}
				aria-pressed={events.activeFilter === null}
				class="rounded-full border px-3 py-1 text-sm transition-colors duration-150 {events.activeFilter ===
				null
					? 'border-accent/40 bg-accent/10 text-accent'
					: 'border-line bg-surface text-ink-muted hover:border-ink-faint/60'}"
			>
				{t('home.filter.all')}
			</button>
			{#each events.chips as chip (chip.id)}
				<button
					type="button"
					onclick={() => events.setFilter(chip.id)}
					aria-pressed={events.activeFilter === chip.id}
					class="rounded-full border px-3 py-1 text-sm transition-colors duration-150 {events.activeFilter ===
					chip.id
						? 'border-accent/40 bg-accent/10 text-accent'
						: 'border-line bg-surface text-ink-muted hover:border-ink-faint/60'}"
				>
					{chip.name}
				</button>
			{/each}
		</div>
	{/if}

	<div class="flex flex-col gap-7">
		{#each events.days as day (day.key)}
			<section class="flex flex-col gap-2.5">
				<h2 class="text-xs font-semibold tracking-wide text-ink-faint uppercase">
					{dayLabel(day)}
				</h2>
				{#each day.events as event (event.id)}
					<!-- eslint-disable svelte/no-navigation-without-resolve -->
					<a
						href={eventHref(event)}
						class="flex items-center gap-3 rounded-xl border border-line bg-surface p-3.5 transition-colors duration-150 hover:border-ink-faint/50"
					>
						<div
							class="flex size-11 shrink-0 flex-col items-center justify-center rounded-lg bg-accent/8 font-semibold text-accent"
							aria-hidden="true"
						>
							<span class="text-base leading-none">{dayNumber(event.starts_at)}</span>
						</div>
						<div class="min-w-0 flex-1">
							<p class="truncate font-medium text-ink">{event.title}</p>
							<p class="flex flex-wrap items-baseline gap-x-2 text-sm text-ink-muted">
								<span
									>{event.all_day
										? t('events.allDay')
										: formatTime(event.starts_at, i18n.locale)}</span
								>
								<span class="text-ink-faint">·</span>
								<span class="truncate">{event.community.name}</span>
								{#if event.group}
									<span class="text-ink-faint">·</span>
									<span class="truncate text-ink-faint">{event.group.name}</span>
								{/if}
							</p>
						</div>
						{#if event.my_rsvp === 'yes'}
							<span class="shrink-0 text-xs font-medium text-accent">{t('home.rsvpGoing')}</span>
						{/if}
					</a>
					<!-- eslint-enable svelte/no-navigation-without-resolve -->
				{/each}
			</section>
		{/each}
	</div>
{/if}
