<script lang="ts">
	import { onMount } from 'svelte';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import {
		fetchPublicEvent,
		fetchPublicGroup,
		requestGuestClaim,
		requestGuestRsvp,
		type Group,
		type RsvpStatus
	} from '$lib/public/api.js';
	import { safeHttpUrl } from '$lib/url.js';
	import type { Event } from '$lib/events/types.js';
	import { formatDate, formatDateTime } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import Chip from '$lib/ui/Chip.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Markdown from '$lib/ui/Markdown.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';
	import GuestRequestForm from '$lib/public/components/GuestRequestForm.svelte';
	import PublicCommentList from '$lib/public/components/PublicCommentList.svelte';

	// A single event, publicly readable (issue #185 slice B), hosting the
	// guest RSVP and signup-slot-claim request forms when the host group
	// opted in (`guest_rsvp_allowed`, SPEC §6 — the same flag governs both
	// requests server-side, see `Kammer.Authorization.can_guest_rsvp?/1`).
	// The group is fetched alongside the event purely for that flag: the
	// event only carries a `{id, name, slug}` group summary, not the
	// group's guest settings.
	let loadState = $state<'loading' | 'ready' | 'error'>('loading');
	let event = $state<Event | null>(null);
	let group = $state<Group | null>(null);
	let rsvpStatus = $state<RsvpStatus>('yes');
	let claimingSlotId = $state<string | null>(null);
	let showRsvpForm = $state(false);

	const communitySlug = $derived(page.params.community!);
	const eventId = $derived(page.params.event!);

	// Only http(s) becomes a clickable link — see safeHttpUrl (issue #247).
	const safeLocationUrl = $derived(safeHttpUrl(event?.location_url));

	onMount(async () => {
		try {
			const fetchedEvent = await fetchPublicEvent(window.location.origin, communitySlug, eventId);
			event = fetchedEvent;
			if (fetchedEvent.group) {
				group = await fetchPublicGroup(
					window.location.origin,
					communitySlug,
					fetchedEvent.group.slug
				);
			}
			loadState = 'ready';
		} catch {
			loadState = 'error';
		}
	});

	const when = $derived(
		event
			? event.all_day
				? formatDate(event.starts_at, i18n.locale)
				: formatDateTime(event.starts_at, i18n.locale)
			: ''
	);

	async function submitRsvp(identity: { email: string; displayName: string }): Promise<void> {
		await requestGuestRsvp(window.location.origin, communitySlug, eventId, identity, rsvpStatus);
	}

	function submitClaim(
		slotId: string
	): (identity: { email: string; displayName: string }) => Promise<void> {
		return async (identity) => {
			await requestGuestClaim(window.location.origin, communitySlug, eventId, slotId, identity);
		};
	}
</script>

<svelte:head
	><title>{event ? event.title : t('public.event.loading')} · {t('app.name')}</title></svelte:head
>

<PublicShell maxWidth="max-w-2xl">
	{#if loadState === 'loading'}
		<div aria-busy="true" aria-live="polite">
			<p class="text-center text-sm text-ink-muted">{t('public.event.loading')}</p>
			<div class="mt-6 flex flex-col gap-3">
				<Skeleton class="h-6 w-2/3" />
				<Skeleton class="h-24 w-full" />
			</div>
		</div>
	{:else if loadState === 'error' || !event}
		<EmptyState title={t('public.event.error.title')} body={t('public.event.error.body')} />
	{:else}
		{#if event.group}
			<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
			<a
				href={resolve(`/c/${communitySlug}/g/${event.group.slug}`)}
				class="text-sm text-ink-muted underline decoration-line underline-offset-4 transition-colors duration-150 hover:text-ink"
			>
				← {event.group.name}
			</a>
		{/if}

		<h1 class="mt-2 text-xl font-semibold tracking-tight text-ink">{event.title}</h1>
		<p class="mt-1 text-sm text-ink-muted">{when}</p>
		{#if event.location_name}
			<p class="mt-0.5 text-sm text-ink-muted">
				{#if safeLocationUrl}
					<!-- eslint-disable svelte/no-navigation-without-resolve -->
					<a
						href={safeLocationUrl}
						rel="noopener noreferrer"
						target="_blank"
						class="text-accent hover:underline"
					>
						{event.location_name}
					</a>
					<!-- eslint-enable svelte/no-navigation-without-resolve -->
				{:else}
					{event.location_name}
				{/if}
			</p>
		{/if}

		{#if event.cancelled}
			<div class="mt-3">
				<Chip>{t('events.detail.cancelled')}</Chip>
			</div>
		{/if}

		{#if event.description_markdown}
			<Markdown source={event.description_markdown} class="mt-4 text-ink" />
		{/if}

		<div class="mt-4 flex flex-wrap gap-2">
			<Chip>{t('events.rsvp.yes')} · {event.rsvp_counts.yes}</Chip>
			<Chip>{t('events.rsvp.maybe')} · {event.rsvp_counts.maybe}</Chip>
			<Chip>{t('events.rsvp.no')} · {event.rsvp_counts.no}</Chip>
		</div>

		{#if group?.guest_rsvp_allowed && !event.cancelled}
			<section class="mt-6 rounded-xl border border-line bg-surface p-4">
				{#if !showRsvpForm}
					<Button
						id="public-event-rsvp-reveal"
						variant="primary"
						onclick={() => (showRsvpForm = true)}
					>
						{t('public.event.rsvpForm.title')}
					</Button>
				{:else}
					<h2 class="text-sm font-semibold text-ink">{t('public.event.rsvpForm.title')}</h2>
					<div class="mt-3">
						<GuestRequestForm
							idPrefix="public-event-rsvp"
							onSubmit={submitRsvp}
							submitLabel={t('public.event.rsvpForm.submit')}
							successTitle={t('public.event.rsvpForm.success.title')}
							successBody={t('public.event.rsvpForm.success.body')}
						>
							{#snippet extra()}
								<div
									class="flex overflow-hidden rounded-lg border border-line"
									role="radiogroup"
									aria-label={t('events.rsvp.label')}
								>
									{#each ['yes', 'maybe', 'no'] as const as status (status)}
										<button
											type="button"
											id="public-event-rsvp-status-{status}"
											role="radio"
											aria-checked={rsvpStatus === status}
											onclick={() => (rsvpStatus = status)}
											class="flex-1 px-3 py-2 text-sm transition-colors duration-150 {rsvpStatus ===
											status
												? 'bg-accent/10 font-medium text-accent'
												: 'text-ink-muted hover:bg-ink/5'}"
										>
											{t(`events.rsvp.${status}`)}
										</button>
									{/each}
								</div>
							{/snippet}
						</GuestRequestForm>
					</div>
				{/if}
			</section>
		{/if}

		{#if event.slots.length > 0}
			<section class="mt-8" aria-labelledby="public-event-slots-heading">
				<h2 id="public-event-slots-heading" class="text-sm font-semibold text-ink">
					{t('events.slots.title')}
				</h2>
				<ul class="mt-3 flex flex-col gap-2">
					{#each event.slots as slot (slot.id)}
						{@const room = slot.taken < slot.capacity}
						<li class="rounded-lg border border-line bg-surface p-3">
							<div class="flex items-center justify-between gap-3">
								<div class="min-w-0">
									<p class="truncate font-medium text-ink">{slot.title}</p>
									<p class="text-xs text-ink-faint">
										{t('events.slots.capacity', {
											taken: String(slot.taken),
											capacity: String(slot.capacity)
										})}
									</p>
								</div>
								{#if group?.guest_rsvp_allowed && room && claimingSlotId !== slot.id}
									<Button
										id="public-event-slot-claim-reveal-{slot.id}"
										variant="secondary"
										size="sm"
										onclick={() => (claimingSlotId = slot.id)}
									>
										{t('events.slots.claim')}
									</Button>
								{:else if !room}
									<span class="shrink-0 text-xs font-medium text-ink-faint">
										{t('events.slots.full')}
									</span>
								{/if}
							</div>
							{#if claimingSlotId === slot.id}
								<div class="mt-3 border-t border-line pt-3">
									<GuestRequestForm
										idPrefix="public-event-slot-claim-{slot.id}"
										onSubmit={submitClaim(slot.id)}
										submitLabel={t('public.event.claimForm.submit')}
										successTitle={t('public.event.claimForm.success.title')}
										successBody={t('public.event.claimForm.success.body')}
									/>
								</div>
							{/if}
						</li>
					{/each}
				</ul>
			</section>
		{/if}

		<section class="mt-8" aria-labelledby="public-event-comments-heading">
			<h2 id="public-event-comments-heading" class="text-sm font-semibold text-ink">
				{t('public.event.comments.title')}
			</h2>
			<div class="mt-3">
				<PublicCommentList
					comments={event.comments ?? []}
					emptyLabel={t('public.event.comments.empty')}
				/>
			</div>
		</section>
	{/if}
</PublicShell>
