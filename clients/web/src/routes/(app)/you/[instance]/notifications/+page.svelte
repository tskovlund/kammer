<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { fetchPushConfig } from '$lib/instances/api.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import {
		currentSubscription,
		subscribeToPush,
		unsubscribeFromPush
	} from '$lib/push/subscription.js';
	import { isPushSupported } from '$lib/push/support.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	// A browser holds one push subscription per *origin* (one service
	// worker registration, one PushManager) — see notification-routing.ts's
	// doc comment. Push is only manageable for the instance actually
	// serving this page right now, not merely an added account reachable
	// over CORS from elsewhere.
	const originMatches = $derived.by(() => {
		if (!instance || typeof window === 'undefined') return false;
		try {
			return new URL(instance.baseUrl).origin === window.location.origin;
		} catch {
			return false;
		}
	});

	const supported = isPushSupported();

	let serverEnabled = $state<boolean | null>(null);
	// The raw VAPID key (#251) once the instance metadata is read — the
	// enable button stays disabled until it's in hand.
	let vapidPublicKey = $state<string | null>(null);
	let subscribed = $state(false);
	let busy = $state(false);
	let actionError = $state<string | null>(null);

	$effect(() => {
		const inst = instance;
		if (!inst || !originMatches || !supported) return;

		void fetchPushConfig(inst.baseUrl).then((config) => {
			serverEnabled = config.enabled;
			vapidPublicKey = config.vapidPublicKey;
		});
		void currentSubscription().then((subscription) => {
			subscribed = subscription !== null;
		});
	});

	async function enable(vapidPublicKey: string): Promise<void> {
		if (!instance) return;
		busy = true;
		actionError = null;
		try {
			await subscribeToPush(instance, vapidPublicKey);
			subscribed = true;
		} catch {
			actionError = t('you.notifications.error');
		} finally {
			busy = false;
		}
	}

	async function disable(): Promise<void> {
		if (!instance) return;
		busy = true;
		actionError = null;
		try {
			await unsubscribeFromPush(instance);
			subscribed = false;
		} catch {
			actionError = t('you.notifications.error');
		} finally {
			busy = false;
		}
	}

	const backHref = resolve('/you');
</script>

<svelte:head>
	<title>{t('you.notifications.title')} · {t('app.name')}</title>
</svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')} />
{:else}
	<header class="mb-6 flex flex-col gap-3">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={backHref} class="flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
				<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
			</svg>
			{t('nav.you')}
		</a>
		<div>
			<h1 class="text-xl font-semibold tracking-tight text-ink">
				{t('you.notifications.title')}
			</h1>
			<p class="mt-0.5 text-sm text-ink-muted">
				{instances.solo
					? t('you.notifications.descriptionSolo')
					: t('you.notifications.description', { name: instance.instanceName })}
			</p>
		</div>
	</header>

	{#if !supported}
		<EmptyState
			title={t('you.notifications.unsupported.title')}
			body={t('you.notifications.unsupported.body')}
		/>
	{:else if !originMatches}
		<Card class="p-4 text-sm text-ink-muted">
			<p>{t('you.notifications.wrongOrigin.body', { name: instance.instanceName })}</p>
			<!-- External instance origin, not a SvelteKit route. -->
			<!-- eslint-disable svelte/no-navigation-without-resolve -->
			<a
				href={instance.baseUrl}
				target="_blank"
				rel="noreferrer"
				class="mt-1 block text-accent hover:underline"
			>
				{t('you.notifications.wrongOrigin.visit', { name: instance.instanceName })}
			</a>
			<!-- eslint-enable svelte/no-navigation-without-resolve -->
		</Card>
	{:else if serverEnabled === null}
		<Card class="p-4">
			<Skeleton class="h-4 w-56" />
		</Card>
	{:else if !serverEnabled}
		<EmptyState
			title={t('you.notifications.serverDisabled.title')}
			body={t('you.notifications.serverDisabled.body')}
		/>
	{:else}
		{#if actionError}
			<div
				class="mb-4 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
				role="alert"
			>
				{actionError}
			</div>
		{/if}

		<Card class="flex items-center justify-between gap-3 p-4">
			<p class="text-sm font-medium text-ink">
				{subscribed ? t('you.notifications.status.on') : t('you.notifications.status.off')}
			</p>
			{#if subscribed}
				<Button variant="danger" size="sm" disabled={busy} onclick={disable}>
					{t('you.notifications.disable')}
				</Button>
			{:else}
				<Button
					variant="primary"
					size="sm"
					disabled={busy || !vapidPublicKey}
					onclick={() => vapidPublicKey && void enable(vapidPublicKey)}
				>
					{t('you.notifications.enable')}
				</Button>
			{/if}
		</Card>
	{/if}
{/if}
