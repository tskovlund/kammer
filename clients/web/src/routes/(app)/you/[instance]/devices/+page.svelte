<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { FeedApiError } from '$lib/feed/api.js';
	import { formatDate } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { fetchDevices, revokeDevice } from '$lib/people/api.js';
	import type { Device } from '$lib/people/types.js';
	import Button from '$lib/ui/Button.svelte';
	import Card from '$lib/ui/Card.svelte';
	import Chip from '$lib/ui/Chip.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import ListItem from '$lib/ui/ListItem.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let devices = $state<Device[]>([]);
	let loadState = $state<'loading' | 'ready' | 'error'>('loading');
	let actionError = $state<string | null>(null);
	let busy = $state(false);

	$effect(() => {
		const inst = instance;
		if (!inst) return;

		let cancelled = false;
		loadState = 'loading';

		void (async () => {
			try {
				const next = await fetchDevices(inst);
				if (cancelled) return;
				devices = next;
				loadState = 'ready';
			} catch {
				if (!cancelled) loadState = 'error';
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	async function revoke(device: Device): Promise<void> {
		if (!instance) return;
		if (!window.confirm(t('devices.revokeConfirm'))) return;
		busy = true;
		actionError = null;
		try {
			await revokeDevice(instance, device.id);
			devices = await fetchDevices(instance);
		} catch (error) {
			actionError = error instanceof FeedApiError ? error.message : t('devices.error.body');
		} finally {
			busy = false;
		}
	}

	const backHref = resolve('/you');
</script>

<svelte:head>
	<title>{t('devices.title')} · {t('app.name')}</title>
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
			<h1 class="text-xl font-semibold tracking-tight text-ink">{t('devices.title')}</h1>
			<p class="mt-0.5 text-sm text-ink-muted">
				{t('devices.description', { name: instance.instanceName })}
			</p>
		</div>
	</header>

	{#if loadState === 'loading'}
		<div class="flex flex-col gap-3">
			{#each [0, 1] as skeleton (skeleton)}
				<div class="rounded-xl border border-line bg-surface p-4">
					<Skeleton class="h-4 w-56" />
				</div>
			{/each}
		</div>
	{:else if loadState === 'error'}
		<EmptyState title={t('devices.error.title')} body={t('devices.error.body')} />
	{:else}
		{#if actionError}
			<div
				class="mb-4 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
				role="alert"
			>
				{actionError}
			</div>
		{/if}

		<Card class="divide-y divide-line">
			{#each devices as device (device.id)}
				<ListItem>
					<p class="truncate text-sm font-medium text-ink">
						{device.device_name ?? t('devices.unnamed')}
					</p>
					<p class="truncate text-xs text-ink-muted">
						{t('devices.added', { date: formatDate(device.created_at, i18n.locale) })}
					</p>
					{#snippet trailing()}
						<span class="flex items-center gap-1.5">
							<Chip>{t(`devices.kind.${device.kind}`)}</Chip>
							{#if device.current}
								<Chip tone="accent">{t('devices.current')}</Chip>
							{:else}
								<Button
									size="sm"
									variant="danger"
									disabled={busy}
									onclick={() => void revoke(device)}
								>
									{t('devices.revoke')}
								</Button>
							{/if}
						</span>
					{/snippet}
				</ListItem>
			{/each}
		</Card>
	{/if}
{/if}
