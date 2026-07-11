<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { fetchInstanceStatus } from '$lib/instances/api.js';
	import { fetchLegalPage, type LegalPage, type LegalPageKey } from '$lib/legal/api.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Card from '$lib/ui/Card.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// The operator's legal-pages overview (SPEC §13, issue #259): both
	// pages with their published state — the PWA's equivalent of the
	// LiveView operator nag for pages still showing the built-in
	// template — each linking to its editor. The reads are public; the
	// gate is the per-viewer instance_operator flag (the same flag that
	// showed the link here), since there is no operator-only read to
	// 403 on. The server still enforces on save.
	const KEYS: LegalPageKey[] = ['privacy', 'imprint'];

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let pages = $state<LegalPage[]>([]);
	let loading = $state(true);
	let forbidden = $state(false);
	let failed = $state(false);

	const backHref = resolve('/you');

	$effect(() => {
		const inst = instance;
		if (!inst) return;

		let cancelled = false;
		loading = true;
		forbidden = false;
		failed = false;

		(async () => {
			try {
				const [status, ...resolved] = await Promise.all([
					fetchInstanceStatus(inst),
					...KEYS.map((key) => fetchLegalPage(inst.baseUrl, key))
				]);
				if (cancelled) return;
				if (!status.instanceOperator) {
					// fetchInstanceStatus never throws — a failed status read
					// collapses to {version: null, operator: false}. A reachable
					// server always reports a version, so null means "couldn't
					// check": show the error state, not a false "operators only".
					if (status.version === null) failed = true;
					else forbidden = true;
					return;
				}
				pages = resolved;
			} catch {
				if (!cancelled) failed = true;
			} finally {
				if (!cancelled) loading = false;
			}
		})();

		return () => {
			cancelled = true;
		};
	});
</script>

<svelte:head><title>{t('manage.legal.title')} · {t('app.name')}</title></svelte:head>

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
			<h1 class="text-xl font-semibold tracking-tight text-ink">{t('manage.legal.title')}</h1>
			<p class="mt-0.5 text-sm text-ink-muted">{t('manage.legal.subtitle')}</p>
		</div>
	</header>

	{#if loading}
		<div class="flex flex-col gap-3"><Skeleton class="h-16" /><Skeleton class="h-16" /></div>
	{:else if forbidden}
		<EmptyState title={t('manage.error.forbiddenTitle')} body={t('manage.legal.forbiddenBody')} />
	{:else if failed}
		<EmptyState title={t('manage.error.title')} body={t('manage.error.body')} />
	{:else}
		<Card class="divide-y divide-line">
			{#each pages as legalPage (legalPage.key)}
				<div class="flex items-center gap-3 px-4 py-3">
					<div class="min-w-0 flex-1">
						<p class="truncate text-sm font-medium text-ink">{legalPage.title}</p>
						{#if legalPage.published}
							<p class="text-xs text-ink-faint">{t('manage.legal.published')}</p>
						{:else}
							<p class="text-xs text-danger">{t('manage.legal.unpublishedHint')}</p>
						{/if}
					</div>
					<a
						href={resolve(`/you/${instance.id}/legal/${legalPage.key}`)}
						class="text-sm text-accent hover:underline"
					>
						{t('manage.legal.edit')}
					</a>
				</div>
			{/each}
		</Card>
	{/if}
{/if}
