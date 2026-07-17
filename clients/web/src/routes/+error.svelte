<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import Button from '$lib/ui/Button.svelte';
	import PublicShell from '$lib/ui/PublicShell.svelte';

	// The SPA's floor under every unrenderable route (part of #270): a stale
	// or mistyped URL (404) and anything `hooks.client.ts` surfaced land
	// here instead of SvelteKit's unstyled English fallback. It renders
	// outside the (app) group too — signed in or not — so it assumes no
	// layout data at all: only the status code and the i18n catalog.
	const notFound = $derived(page.status === 404);
</script>

<svelte:head>
	<title>
		{t(notFound ? 'errorPage.notFound.title' : 'errorPage.generic.title')} · {t('app.name')}
	</title>
</svelte:head>

<PublicShell>
	<div class="text-center">
		<p class="text-sm font-medium tracking-wide text-ink-faint">{page.status}</p>
		<h1 class="mt-2 text-base font-medium text-ink">
			{t(notFound ? 'errorPage.notFound.title' : 'errorPage.generic.title')}
		</h1>
		<p class="mt-2 text-sm leading-relaxed text-ink-muted">
			{t(notFound ? 'errorPage.notFound.body' : 'errorPage.generic.body')}
		</p>
		<div class="mt-8">
			<Button id="error-home" href={resolve('/')} variant="primary">
				{t('errorPage.home')}
			</Button>
		</div>
	</div>
</PublicShell>
