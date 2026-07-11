<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { fetchCommunity } from '$lib/feed/api.js';
	import type { Community } from '$lib/feed/types.js';
	import {
		fetchAuditLog,
		loadErrorKind,
		type AuditEvent,
		type ManageErrorKind
	} from '$lib/manage/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import RelativeTime from '$lib/ui/RelativeTime.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let community = $state<Community | null>(null);
	let events = $state<AuditEvent[]>([]);
	let loading = $state(true);
	let error = $state<ManageErrorKind | null>(null);

	const canManage = $derived(community?.viewer_can.includes('manage_community') ?? false);

	$effect(() => {
		const inst = instance;
		const slug = page.params.community;
		if (!inst || !slug) return;

		let cancelled = false;
		loading = true;
		error = null;

		(async () => {
			try {
				// The audit read is silently empty for non-admins (no-oracle),
				// so the community's `viewer_can` is what gates the page.
				const [resolvedCommunity, resolvedEvents] = await Promise.all([
					fetchCommunity(inst, slug),
					fetchAuditLog(inst, slug)
				]);
				if (cancelled) return;
				community = resolvedCommunity;
				events = resolvedEvents;
			} catch (cause) {
				if (!cancelled) error = loadErrorKind(cause);
			} finally {
				if (!cancelled) loading = false;
			}
		})();

		return () => {
			cancelled = true;
		};
	});

	const backHref = $derived(
		resolve(`/i/${page.params.instance}/c/${page.params.community}/moderation`)
	);
</script>

<svelte:head>
	<title>{t('manage.moderation.audit.title')} · {t('app.name')}</title>
</svelte:head>

<header class="mb-5">
	<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
	<a href={backHref} class="flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
		<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
			<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
		</svg>
		{t('manage.moderation.title')}
	</a>
	<h1 class="mt-3 text-xl font-semibold tracking-tight text-ink">
		{t('manage.moderation.audit.title')}
	</h1>
</header>

{#if loading}
	<div class="flex flex-col gap-3">
		<Skeleton class="h-16" />
		<Skeleton class="h-16" />
	</div>
{:else if error === 'forbidden' || (community && !canManage)}
	<EmptyState title={t('manage.error.forbiddenTitle')} body={t('manage.error.forbiddenBody')} />
{:else if error}
	<EmptyState title={t('manage.error.title')} body={t('manage.error.body')} />
{:else if events.length === 0}
	<EmptyState
		title={t('manage.moderation.audit.empty.title')}
		body={t('manage.moderation.audit.empty.body')}
	/>
{:else}
	<Card class="divide-y divide-line">
		{#each events as event (event.id)}
			<div class="px-4 py-3">
				<p class="text-sm text-ink">{event.summary}</p>
				<p class="mt-1 text-xs text-ink-faint">
					<span class="font-mono">{event.action}</span>
					·
					<RelativeTime datetime={event.inserted_at} class="text-xs" />
				</p>
			</div>
		{/each}
	</Card>
{/if}
