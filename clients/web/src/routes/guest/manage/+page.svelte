<script lang="ts">
	import { onMount, tick } from 'svelte';
	import { browser } from '$app/environment';
	import {
		eraseGuest,
		fetchGuestManageState,
		releaseGuestClaim,
		setGuestCadence,
		setGuestRsvp,
		unsubscribeGuest,
		type GuestManageState
	} from '$lib/guest/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import Chip from '$lib/ui/Chip.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import ListItem from '$lib/ui/ListItem.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// Everything behind a guest's management link (issue #185): RSVPs,
	// signup claims, comments, and newsletter subscriptions, all editable
	// from one screen. Every mutation re-fetches the full inventory from
	// the response the API already returns (the "refreshed inventory" each
	// PUT/DELETE answers with), so the list never drifts from the server.
	let loadState = $state<'loading' | 'ready' | 'error'>('loading');
	let data = $state<GuestManageState | null>(null);
	let busyIds = $state<string[]>([]);
	let mutationError = $state<string | null>(null);
	let eraseStep = $state<'idle' | 'confirming' | 'erasing' | 'erased'>('idle');

	let eraseHeading = $state<HTMLElement | null>(null);

	// The management token is long-lived (ADR 0026), so the emailed link
	// carries it in the URL *fragment* (`…/guest/manage#<token>`), which
	// browsers never send to the server — unlike a path segment or query
	// string, it never reaches access logs, proxy logs, or `Referer`. This
	// app is SPA-only (`+layout.ts` sets `ssr = false`), but `browser` is
	// still checked defensively before touching `window`. An empty
	// fragment gets the same neutral error state a bad token would from
	// the API, without ever making the request.
	let token = $state<string | null>(null);

	onMount(async () => {
		if (!browser) return;
		const fragment = window.location.hash.replace(/^#/, '');
		if (fragment === '') {
			loadState = 'error';
			return;
		}
		token = fragment;
		try {
			data = await fetchGuestManageState(window.location.origin, fragment);
			loadState = 'ready';
		} catch {
			loadState = 'error';
		}
	});

	$effect(() => {
		if (eraseStep === 'confirming') void tick().then(() => eraseHeading?.focus());
	});

	function busy(id: string): boolean {
		return busyIds.includes(id);
	}

	async function runMutation(id: string, mutate: () => Promise<GuestManageState>): Promise<void> {
		if (!token) return;
		busyIds = [...busyIds, id];
		mutationError = null;
		try {
			data = await mutate();
		} catch {
			mutationError = t('guest.manage.mutation.error');
		} finally {
			busyIds = busyIds.filter((busyId) => busyId !== id);
		}
	}

	function changeRsvp(eventId: string, status: 'yes' | 'no' | 'maybe'): void {
		const currentToken = token;
		if (!currentToken) return;
		void runMutation(`rsvp-${eventId}`, () =>
			setGuestRsvp(window.location.origin, currentToken, eventId, status)
		);
	}

	function releaseClaim(claimId: string): void {
		const currentToken = token;
		if (!currentToken) return;
		void runMutation(`claim-${claimId}`, () =>
			releaseGuestClaim(window.location.origin, currentToken, claimId)
		);
	}

	function changeCadence(subscriptionId: string, cadence: 'per_post' | 'daily' | 'weekly'): void {
		const currentToken = token;
		if (!currentToken) return;
		void runMutation(`cadence-${subscriptionId}`, () =>
			setGuestCadence(window.location.origin, currentToken, subscriptionId, cadence)
		);
	}

	function unsubscribe(subscriptionId: string): void {
		const currentToken = token;
		if (!currentToken) return;
		void runMutation(`unsub-${subscriptionId}`, () =>
			unsubscribeGuest(window.location.origin, currentToken, subscriptionId)
		);
	}

	function startErase(): void {
		eraseStep = 'confirming';
	}

	// Re-query the trigger button by id rather than holding onto the node
	// captured at click time — the confirm panel replaces it via an
	// `{#if}`, so the original button is destroyed the moment the panel
	// mounts, and focusing a detached node is a no-op. `tick()` waits for
	// Svelte to re-mount the idle branch (and the button with it) first.
	function cancelErase(): void {
		eraseStep = 'idle';
		void tick().then(() => {
			document.getElementById('guest-manage-erase-button')?.focus();
		});
	}

	async function confirmErase(): Promise<void> {
		const currentToken = token;
		if (!currentToken) return;
		eraseStep = 'erasing';
		mutationError = null;
		try {
			await eraseGuest(window.location.origin, currentToken);
			eraseStep = 'erased';
		} catch {
			mutationError = t('guest.manage.mutation.error');
			eraseStep = 'confirming';
		}
	}

	const rsvpStatusLabel = {
		yes: () => t('guest.manage.rsvp.status.yes'),
		no: () => t('guest.manage.rsvp.status.no'),
		maybe: () => t('guest.manage.rsvp.status.maybe')
	};

	const cadenceLabel = {
		per_post: () => t('guest.manage.subscription.cadence.perPost'),
		daily: () => t('guest.manage.subscription.cadence.daily'),
		weekly: () => t('guest.manage.subscription.cadence.weekly')
	};
</script>

<svelte:head><title>{t('guest.manage.title')} · {t('app.name')}</title></svelte:head>

<PublicShell maxWidth="max-w-lg">
	{#if loadState === 'loading'}
		<div aria-busy="true" aria-live="polite">
			<p class="text-center text-sm text-ink-muted">{t('guest.manage.loading')}</p>
			<div class="mt-6 flex flex-col gap-3">
				<Skeleton class="h-20 w-full" />
				<Skeleton class="h-20 w-full" />
			</div>
		</div>
	{:else if loadState === 'error'}
		<EmptyState title={t('guest.manage.error.title')} body={t('guest.manage.error.body')} />
	{:else if eraseStep === 'erased'}
		<EmptyState title={t('guest.manage.erased.title')} body={t('guest.manage.erased.body')} />
	{:else if data}
		<h1 class="text-lg font-semibold text-ink">{t('guest.manage.title')}</h1>
		<p class="mt-1 text-sm text-ink-muted">{data.identity.display_name} · {data.identity.email}</p>

		{#if mutationError}
			<div
				class="mt-4 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
				role="alert"
			>
				{mutationError}
			</div>
		{/if}

		<!-- RSVPs -->
		<section class="mt-8" aria-labelledby="guest-manage-rsvps-heading">
			<h2
				id="guest-manage-rsvps-heading"
				class="text-sm font-medium uppercase tracking-wide text-ink-faint"
			>
				{t('guest.manage.sections.rsvps')}
			</h2>
			{#if data.rsvps.length === 0}
				<p class="mt-2 text-sm text-ink-muted">{t('guest.manage.empty.rsvps')}</p>
			{:else}
				<Card class="mt-2 divide-y divide-line">
					{#each data.rsvps as rsvp (rsvp.event_id)}
						<ListItem>
							<p class="truncate text-sm font-medium text-ink">{rsvp.event_title}</p>
							{#snippet trailing()}
								<label class="flex items-center gap-2">
									<span class="sr-only" id="rsvp-status-label-{rsvp.event_id}">
										{t('guest.manage.rsvp.changeLabel', { event: rsvp.event_title })}
									</span>
									<select
										id="guest-manage-rsvp-{rsvp.event_id}"
										aria-labelledby="rsvp-status-label-{rsvp.event_id}"
										value={rsvp.status}
										disabled={busy(`rsvp-${rsvp.event_id}`)}
										onchange={(changeEvent) =>
											changeRsvp(
												rsvp.event_id,
												changeEvent.currentTarget.value as 'yes' | 'no' | 'maybe'
											)}
										class="h-10 rounded-lg border border-line bg-surface px-2 text-sm text-ink"
									>
										{#each ['yes', 'maybe', 'no'] as const as status (status)}
											<option value={status}>{rsvpStatusLabel[status]()}</option>
										{/each}
									</select>
								</label>
							{/snippet}
						</ListItem>
					{/each}
				</Card>
			{/if}
		</section>

		<!-- Signup claims -->
		<section class="mt-8" aria-labelledby="guest-manage-claims-heading">
			<h2
				id="guest-manage-claims-heading"
				class="text-sm font-medium uppercase tracking-wide text-ink-faint"
			>
				{t('guest.manage.sections.claims')}
			</h2>
			{#if data.claims.length === 0}
				<p class="mt-2 text-sm text-ink-muted">{t('guest.manage.empty.claims')}</p>
			{:else}
				<Card class="mt-2 divide-y divide-line">
					{#each data.claims as claim (claim.claim_id)}
						<ListItem>
							<p class="truncate text-sm font-medium text-ink">{claim.slot_title}</p>
							<p class="truncate text-xs text-ink-muted">{claim.event_title}</p>
							{#snippet trailing()}
								<Button
									id="guest-manage-claim-release-{claim.claim_id}"
									variant="danger"
									size="sm"
									disabled={busy(`claim-${claim.claim_id}`)}
									onclick={() => releaseClaim(claim.claim_id)}
								>
									{t('guest.manage.claim.release')}
								</Button>
							{/snippet}
						</ListItem>
					{/each}
				</Card>
			{/if}
		</section>

		<!-- Comments -->
		<section class="mt-8" aria-labelledby="guest-manage-comments-heading">
			<h2
				id="guest-manage-comments-heading"
				class="text-sm font-medium uppercase tracking-wide text-ink-faint"
			>
				{t('guest.manage.sections.comments')}
			</h2>
			{#if data.comments.length === 0}
				<p class="mt-2 text-sm text-ink-muted">{t('guest.manage.empty.comments')}</p>
			{:else}
				<Card class="mt-2 divide-y divide-line">
					{#each data.comments as comment, index (index)}
						<ListItem>
							<p class="truncate text-xs text-ink-faint">{comment.group_name}</p>
							<p class="mt-0.5 line-clamp-2 text-sm text-ink">{comment.body_markdown}</p>
							{#snippet trailing()}
								{#if comment.removed}
									<Chip tone="neutral">{t('guest.manage.comment.removed')}</Chip>
								{:else if comment.pending_approval}
									<Chip tone="accent">{t('guest.manage.comment.pending')}</Chip>
								{/if}
							{/snippet}
						</ListItem>
					{/each}
				</Card>
			{/if}
		</section>

		<!-- Newsletter subscriptions -->
		<section class="mt-8" aria-labelledby="guest-manage-subscriptions-heading">
			<h2
				id="guest-manage-subscriptions-heading"
				class="text-sm font-medium uppercase tracking-wide text-ink-faint"
			>
				{t('guest.manage.sections.subscriptions')}
			</h2>
			{#if data.subscriptions.length === 0}
				<p class="mt-2 text-sm text-ink-muted">{t('guest.manage.empty.subscriptions')}</p>
			{:else}
				<Card class="mt-2 divide-y divide-line">
					{#each data.subscriptions as subscription (subscription.subscription_id)}
						<ListItem>
							<p class="truncate text-sm font-medium text-ink">
								{subscription.community_name} · {subscription.group_name}
							</p>
							{#snippet trailing()}
								<div class="flex items-center gap-2">
									<label class="flex items-center gap-2">
										<span class="sr-only" id="cadence-label-{subscription.subscription_id}">
											{t('guest.manage.subscription.changeLabel', {
												group: subscription.group_name
											})}
										</span>
										<select
											id="guest-manage-cadence-{subscription.subscription_id}"
											aria-labelledby="cadence-label-{subscription.subscription_id}"
											value={subscription.cadence}
											disabled={busy(`cadence-${subscription.subscription_id}`)}
											onchange={(changeEvent) =>
												changeCadence(
													subscription.subscription_id,
													changeEvent.currentTarget.value as 'per_post' | 'daily' | 'weekly'
												)}
											class="h-10 rounded-lg border border-line bg-surface px-2 text-sm text-ink"
										>
											{#each ['per_post', 'daily', 'weekly'] as const as cadence (cadence)}
												<option value={cadence}>{cadenceLabel[cadence]()}</option>
											{/each}
										</select>
									</label>
									<Button
										id="guest-manage-unsubscribe-{subscription.subscription_id}"
										variant="danger"
										size="sm"
										disabled={busy(`unsub-${subscription.subscription_id}`)}
										onclick={() => unsubscribe(subscription.subscription_id)}
									>
										{t('guest.manage.subscription.unsubscribe')}
									</Button>
								</div>
							{/snippet}
						</ListItem>
					{/each}
				</Card>
			{/if}
		</section>

		<!-- Erase everything -->
		<section class="mt-10 border-t border-line pt-6">
			{#if eraseStep === 'idle'}
				<Button id="guest-manage-erase-button" variant="danger" onclick={startErase}>
					{t('guest.manage.erase.button')}
				</Button>
			{:else}
				<div
					class="rounded-xl border border-danger/30 bg-danger/5 p-4"
					role="alertdialog"
					aria-labelledby="guest-manage-erase-heading"
					aria-describedby="guest-manage-erase-body"
				>
					<h2
						id="guest-manage-erase-heading"
						tabindex="-1"
						bind:this={eraseHeading}
						class="text-sm font-semibold text-ink focus:outline-none"
					>
						{t('guest.manage.erase.confirm.title')}
					</h2>
					<p id="guest-manage-erase-body" class="mt-1 text-sm text-ink-muted">
						{t('guest.manage.erase.confirm.body')}
					</p>
					<div class="mt-4 flex gap-2">
						<Button
							id="guest-manage-erase-confirm"
							variant="danger"
							disabled={eraseStep === 'erasing'}
							onclick={confirmErase}
						>
							{t('guest.manage.erase.confirm.submit')}
						</Button>
						<Button
							id="guest-manage-erase-cancel"
							variant="ghost"
							disabled={eraseStep === 'erasing'}
							onclick={cancelErase}
						>
							{t('guest.manage.erase.confirm.cancel')}
						</Button>
					</div>
				</div>
			{/if}
		</section>
	{/if}
</PublicShell>
