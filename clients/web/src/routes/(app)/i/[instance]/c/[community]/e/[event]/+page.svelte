<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import * as api from '$lib/events/api.js';
	import { createEventStore, type EventStore } from '$lib/events/event-store.svelte.js';
	import { safeHttpUrl } from '$lib/url.js';
	import EventComments from '$lib/events/components/EventComments.svelte';
	import RsvpControl from '$lib/events/components/RsvpControl.svelte';
	import SlotList from '$lib/events/components/SlotList.svelte';
	import { formatDate, formatDateTime } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Markdown from '$lib/ui/Markdown.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let store = $state<EventStore | null>(null);
	let managing = $state(false);

	const communitySlug = $derived(page.params.community!);
	const eventId = $derived(page.params.event!);

	$effect(() => {
		const inst = instance;
		const community = page.params.community;
		const id = page.params.event;
		if (!inst || !community || !id) return;

		const localStore = createEventStore(inst, community, id);
		store = localStore;
		void localStore.load();
	});

	const event = $derived(store?.event ?? null);

	// Only http(s) becomes a clickable link — see safeHttpUrl (issue #247).
	const eventLocationUrl = $derived(safeHttpUrl(event?.location_url));

	const when = $derived(
		event
			? event.all_day
				? formatDate(event.starts_at, i18n.locale)
				: formatDateTime(event.starts_at, i18n.locale)
			: ''
	);

	const homeHref = resolve('/events');
	const editHref = $derived(
		resolve(`/i/${page.params.instance}/c/${communitySlug}/e/${eventId}/edit`)
	);
	// The organizer view of the whole series. Shown when this event is an
	// occurrence; the series page fails closed for non-managers, same as the
	// other manage actions (#199).
	const seriesHref = $derived(
		event?.series_id
			? resolve(`/i/${page.params.instance}/c/${communitySlug}/series/${event.series_id}`)
			: ''
	);

	async function toggleCancelled(): Promise<void> {
		if (!store || !event || !instance) return;
		try {
			await api.setCancelled(instance, communitySlug, eventId, !event.cancelled);
			await store.load();
		} catch {
			await store.load();
		}
	}

	async function removeEvent(): Promise<void> {
		if (!instance) return;
		try {
			await api.deleteEvent(instance, communitySlug, eventId);
			await goto(homeHref);
		} catch (error) {
			// Surface via the store's action error channel by reloading.
			void error;
			await store?.load();
		}
	}
</script>

<svelte:head><title>{event?.title ?? t('nav.events')} · {t('app.name')}</title></svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')}>
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={resolve('/events')} class="text-sm text-accent hover:underline">{t('common.back')}</a>
	</EmptyState>
{:else}
	<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
	<a href={homeHref} class="mb-4 flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
		<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
			<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
		</svg>
		{t('nav.events')}
	</a>

	{#if store?.loadState === 'loading'}
		<div class="flex flex-col gap-4">
			<Skeleton class="h-7 w-2/3" />
			<Skeleton class="h-4 w-1/2" />
			<Skeleton class="h-24 w-full" />
		</div>
	{:else if store?.loadState === 'error' || !event}
		<EmptyState
			title={store?.loadErrorKind === 'auth' ? t('feed.error.authTitle') : t('feed.error.title')}
			body={store?.loadErrorKind === 'auth' ? t('feed.error.authBody') : t('feed.error.body')}
		>
			<Button variant="secondary" size="sm" onclick={() => store?.load()}
				>{t('common.retry')}</Button
			>
		</EmptyState>
	{:else}
		<article class="flex flex-col gap-6">
			<header class="flex flex-col gap-2">
				<h1 class="text-2xl font-semibold tracking-tight text-ink">{event.title}</h1>
				<p class="flex flex-wrap items-center gap-x-2 text-sm text-ink-muted">
					<span>{when}</span>
					{#if event.group}
						<span class="text-ink-faint">·</span>
						<span>{event.group.name}</span>
					{/if}
					{#if event.location_name}
						<span class="text-ink-faint">·</span>
						{#if eventLocationUrl}
							<!-- eslint-disable svelte/no-navigation-without-resolve -->
							<a
								href={eventLocationUrl}
								rel="noopener noreferrer"
								target="_blank"
								class="text-accent hover:underline"
							>
								{event.location_name}
							</a>
							<!-- eslint-enable svelte/no-navigation-without-resolve -->
						{:else}
							<span>{event.location_name}</span>
						{/if}
					{/if}
				</p>

				{#if event.cancelled}
					<p
						class="rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
						role="status"
					>
						{t('events.detail.cancelled')}
					</p>
				{:else if event.series_id}
					<p class="text-sm text-ink-faint">{t('events.detail.partOfSeries')}</p>
				{/if}
			</header>

			{#if store?.actionError}
				<div
					class="flex items-center justify-between gap-3 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
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

			{#if !event.cancelled}
				<RsvpControl {event} onRsvp={(status) => store?.rsvp(status)} />
			{/if}

			{#if event.description_markdown}
				<Markdown source={event.description_markdown} class="text-ink" />
			{/if}

			<SlotList {event} store={store!} currentUserId={instance.user.id} />

			<div class="flex flex-wrap items-center gap-3">
				<!-- eslint-disable svelte/no-navigation-without-resolve -->
				<a
					href={api.icsUrl(instance, communitySlug, eventId)}
					class="inline-flex items-center gap-1.5 text-sm text-accent hover:underline"
				>
					<svg
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="1.5"
						class="size-4"
					>
						<path
							stroke-linecap="round"
							stroke-linejoin="round"
							d="M3 8.25V18a2.25 2.25 0 002.25 2.25h13.5A2.25 2.25 0 0021 18V8.25m-18 0V6a2.25 2.25 0 012.25-2.25h13.5A2.25 2.25 0 0121 6v2.25m-18 0h18M12 12.75l3 3m0 0l-3 3m3-3H9"
						/>
					</svg>
					{t('events.detail.addToCalendar')}
				</a>

				<button
					type="button"
					class="text-sm text-ink-faint hover:text-ink-muted"
					aria-expanded={managing}
					onclick={() => (managing = !managing)}
				>
					{t('events.detail.manage')}
				</button>
			</div>

			{#if managing}
				<!-- #199: no per-viewer capabilities yet, so manage actions show to
				     everyone and fail closed with a toast if the caller isn't allowed. -->
				<div class="flex flex-wrap items-center gap-2 rounded-lg border border-line p-3">
					<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
					<a href={editHref} class="inline-flex"
						><Button variant="secondary" size="sm">{t('common.edit')}</Button></a
					>
					{#if event.series_id}
						<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
						<a href={seriesHref} class="inline-flex"
							><Button variant="secondary" size="sm">{t('events.detail.viewSeries')}</Button></a
						>
						<Button variant="secondary" size="sm" onclick={toggleCancelled}>
							{event.cancelled ? t('events.detail.reinstate') : t('events.detail.cancelOccurrence')}
						</Button>
					{/if}
					<Button variant="danger" size="sm" onclick={removeEvent}>{t('common.delete')}</Button>
				</div>
			{/if}

			<EventComments
				comments={event.comments}
				store={store!}
				currentUserId={instance.user.id}
				locked={event.comments_locked}
			/>
		</article>
	{/if}
{/if}
