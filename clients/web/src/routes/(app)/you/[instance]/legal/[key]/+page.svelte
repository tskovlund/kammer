<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { fetchInstanceStatus } from '$lib/instances/api.js';
	import { fetchLegalPage, type LegalPage, type LegalPageKey } from '$lib/legal/api.js';
	import { ManageApiError, updateLegalPage } from '$lib/manage/api.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// The legal-page editor (SPEC §13, issue #259) — the PWA twin of
	// LiveView's LegalLive.Edit: a markdown textarea over the operator-only
	// PUT, prefilled with the built-in template until the operator
	// publishes their own text. The public page itself is the preview
	// reference, linked below. Gated on the per-viewer instance_operator
	// flag (there is no operator-only read here); the server still
	// enforces on save.
	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);
	const key = $derived(
		page.params.key === 'privacy' || page.params.key === 'imprint'
			? (page.params.key as LegalPageKey)
			: null
	);

	let legalPage = $state<LegalPage | null>(null);
	let content = $state('');
	let loading = $state(true);
	let forbidden = $state(false);
	let failed = $state(false);
	let saving = $state(false);
	let saved = $state(false);
	let saveError = $state<string | null>(null);

	const backHref = $derived(resolve(`/you/${page.params.instance}/legal`));
	const publicHref = $derived(instance ? `${instance.baseUrl}/legal/${key}` : '#');

	$effect(() => {
		const inst = instance;
		const pageKey = key;
		if (!inst || !pageKey) return;

		let cancelled = false;
		loading = true;
		forbidden = false;
		failed = false;
		saved = false;
		saveError = null;

		(async () => {
			try {
				const [status, resolved] = await Promise.all([
					fetchInstanceStatus(inst),
					fetchLegalPage(inst.baseUrl, pageKey)
				]);
				if (cancelled) return;
				if (!status.instanceOperator) {
					// A failed status read collapses to {version: null, operator:
					// false} — null version means "couldn't check", not "not an
					// operator" (same fix as the overview page).
					if (status.version === null) failed = true;
					else forbidden = true;
					return;
				}
				legalPage = resolved;
				content = resolved.content_markdown;
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

	async function save(event: SubmitEvent) {
		event.preventDefault();
		if (!instance || !key || saving) return;
		saving = true;
		saved = false;
		saveError = null;
		try {
			legalPage = await updateLegalPage(instance, key, content);
			content = legalPage.content_markdown;
			saved = true;
		} catch (cause) {
			// A 422's field name keys our own copy (#253): content_markdown
			// means empty or over the 100k-character cap.
			if (
				cause instanceof ManageApiError &&
				cause.kind === 'validation' &&
				cause.details.content_markdown
			) {
				saveError = t('manage.legal.errorContent');
			} else if (cause instanceof ManageApiError && cause.kind === 'forbidden') {
				saveError = t('manage.legal.forbiddenBody');
			} else {
				saveError = t('manage.error.body');
			}
		} finally {
			saving = false;
		}
	}
</script>

<svelte:head>
	<title>{legalPage ? legalPage.title : t('manage.legal.title')} · {t('app.name')}</title>
</svelte:head>

{#if !instance || !key}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')} />
{:else}
	<header class="mb-6 flex flex-col gap-3">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={backHref} class="flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
				<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
			</svg>
			{t('manage.legal.title')}
		</a>
		<div>
			<h1 class="text-xl font-semibold tracking-tight text-ink">
				{legalPage ? legalPage.title : t('manage.legal.title')}
			</h1>
			<p class="mt-0.5 text-sm text-ink-muted">{t('manage.legal.editSubtitle')}</p>
		</div>
	</header>

	{#if loading}
		<div class="flex flex-col gap-3"><Skeleton class="h-11" /><Skeleton class="h-48" /></div>
	{:else if forbidden}
		<EmptyState title={t('manage.error.forbiddenTitle')} body={t('manage.legal.forbiddenBody')} />
	{:else if failed || !legalPage}
		<EmptyState title={t('manage.error.title')} body={t('manage.error.body')} />
	{:else}
		{#if !legalPage.published}
			<p class="mb-4 rounded-lg border border-line bg-paper px-3 py-2 text-sm text-ink-muted">
				{t('manage.legal.unpublishedHint')}
			</p>
		{/if}

		<form class="flex max-w-2xl flex-col gap-4" onsubmit={save}>
			<div class="flex flex-col gap-1.5">
				<label for="legal-content" class="text-sm font-medium text-ink">
					{t('manage.legal.content')}
				</label>
				<textarea
					id="legal-content"
					bind:value={content}
					rows="20"
					required
					class="rounded-lg border border-line bg-surface px-3 py-2 font-mono text-sm text-ink focus:border-accent focus:outline-none"
				></textarea>
				<p class="text-sm text-ink-faint">{t('manage.legal.contentHint')}</p>
			</div>

			<div class="flex items-center gap-3">
				<Button type="submit" variant="primary" disabled={saving || content.trim() === ''}>
					{saving ? t('common.sending') : t('manage.legal.publish')}
				</Button>
				<!-- The public page itself is the preview reference — an external
				     absolute URL on the instance's own origin, not an app route. -->
				<!-- eslint-disable svelte/no-navigation-without-resolve -->
				<a
					href={publicHref}
					target="_blank"
					rel="noopener"
					class="text-sm text-accent hover:underline"
				>
					{t('manage.legal.viewPublic')}
				</a>
				<!-- eslint-enable svelte/no-navigation-without-resolve -->
				{#if saved}
					<span class="text-sm text-ink-muted" role="status">{t('manage.legal.publishedNow')}</span>
				{/if}
				{#if saveError}
					<span class="text-sm text-danger" role="alert">{saveError}</span>
				{/if}
			</div>
		</form>
	{/if}
{/if}
