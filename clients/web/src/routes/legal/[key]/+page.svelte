<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import { fetchLegalPage, type LegalPage } from '$lib/legal/api.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Markdown from '$lib/ui/Markdown.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';
	import Skeleton from '$lib/ui/Skeleton.svelte';

	// Public legal page (privacy/imprint, SPEC §13) — tokenless and
	// unauthenticated like the rest of #185's surfaces. Renders the
	// authored `content_markdown` through the same `Markdown` component
	// (and the same sanitized markdown-it pipeline) the feed uses, rather
	// than trusting the server's pre-rendered `content_html` via a second
	// {@html} sink — one audited HTML sink is easier to reason about than
	// two.
	let loadState = $state<'loading' | 'ready' | 'error'>('loading');
	let content = $state<LegalPage | null>(null);

	onMount(async () => {
		const key = page.params.key;
		if (!key) {
			loadState = 'error';
			return;
		}
		try {
			content = await fetchLegalPage(window.location.origin, key);
			loadState = 'ready';
		} catch {
			loadState = 'error';
		}
	});
</script>

<svelte:head>
	<title>{content ? content.title : t('legal.loading')} · {t('app.name')}</title>
</svelte:head>

<PublicShell maxWidth="max-w-2xl">
	{#if loadState === 'loading'}
		<div aria-busy="true" aria-live="polite">
			<p class="text-center text-sm text-ink-muted">{t('legal.loading')}</p>
			<div class="mt-6 flex flex-col gap-3">
				<Skeleton class="h-6 w-2/3" />
				<Skeleton class="h-4 w-full" />
				<Skeleton class="h-4 w-full" />
				<Skeleton class="h-4 w-5/6" />
			</div>
		</div>
	{:else if loadState === 'error' || !content}
		<EmptyState title={t('legal.error.title')} body={t('legal.error.body')} />
	{:else}
		<h1 class="text-xl font-semibold tracking-tight text-ink">{content.title}</h1>
		<Markdown source={content.content_markdown} class="mt-6" />
	{/if}
</PublicShell>
