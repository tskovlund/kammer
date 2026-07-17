<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { errorKind, type ApiErrorKind } from '$lib/api/errors.js';
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
	import ErrorBanner from '$lib/ui/ErrorBanner.svelte';
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

	// "Add to calendar" (issue #307): the ICS download sits behind Bearer
	// auth — a plain <a href> can't carry the device token, and the
	// tokenless route 404'd every members-only event.
	let downloadingIcs = $state(false);
	let icsError = $state<ApiErrorKind | null>(null);

	async function downloadIcs(): Promise<void> {
		if (!instance) return;
		downloadingIcs = true;
		icsError = null;
		try {
			const url = await api.fetchEventIcsUrl(instance, communitySlug, eventId);
			// Same anchor dance as the account page's export download.
			const anchor = document.createElement('a');
			anchor.href = url;
			anchor.download = 'kammer.ics';
			anchor.rel = 'noopener';
			document.body.appendChild(anchor);
			anchor.click();
			anchor.remove();
			URL.revokeObjectURL(url);
		} catch (error) {
			icsError = errorKind(error);
		} finally {
			downloadingIcs = false;
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
				<ErrorBanner kind={store.actionError} ondismiss={() => store?.clearActionError()} />
			{/if}

			{#if !event.cancelled}
				<div class="flex flex-col gap-2">
					<RsvpControl {event} onRsvp={(status) => store?.rsvp(status)} />

					{#if event.capacity != null}
						<p id="event-capacity-line" class="text-sm text-ink-muted">
							{t('events.detail.attendingWithCapacity', {
								attending: String(event.rsvp_counts.yes),
								capacity: String(event.capacity)
							})}
							{#if event.rsvp_counts.yes >= event.capacity && event.my_rsvp !== 'yes' && event.my_rsvp !== 'waitlisted'}
								· {t('events.detail.fullHint')}
							{/if}
						</p>
					{/if}

					{#if event.my_rsvp === 'waitlisted'}
						<p
							id="event-waitlist-notice"
							class="rounded-lg border border-accent/30 bg-accent/5 px-3 py-2 text-sm text-accent"
							role="status"
						>
							{#if event.waitlist_position != null}
								{t('events.detail.waitlistPosition', {
									position: String(event.waitlist_position)
								})}
							{:else}
								{t('events.detail.waitlisted')}
							{/if}
						</p>
					{/if}
				</div>
			{/if}

			{#if event.description_markdown}
				<Markdown source={event.description_markdown} class="text-ink" />
			{/if}

			{#if event.waitlist.length > 0}
				<!-- The ordered queue — the attendee-list counterpart the organizer
				     reads; the same name exposure slot claimants already have. -->
				<section class="flex flex-col gap-2" aria-labelledby="event-waitlist-heading">
					<h2
						id="event-waitlist-heading"
						class="text-xs font-medium tracking-wide text-ink-faint uppercase"
					>
						{t('events.detail.waitlistTitle')}
					</h2>
					<ol id="event-waitlist" class="flex flex-col gap-1">
						{#each event.waitlist as entry (entry.position)}
							<li class="text-sm text-ink">
								<span class="text-ink-faint">{entry.position}.</span>
								{entry.attendee?.display_name ?? t('feed.author.unknown')}
							</li>
						{/each}
					</ol>
				</section>
			{/if}

			<SlotList {event} store={store!} currentUserId={instance.user.id} />

			{#if icsError}
				<ErrorBanner kind={icsError} ondismiss={() => (icsError = null)} />
			{/if}

			<div class="flex flex-wrap items-center gap-3">
				<button
					type="button"
					id="event-ics-download"
					class="inline-flex items-center gap-1.5 text-sm text-accent hover:underline disabled:cursor-default disabled:opacity-60 disabled:hover:no-underline"
					disabled={downloadingIcs}
					onclick={downloadIcs}
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
				</button>

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
