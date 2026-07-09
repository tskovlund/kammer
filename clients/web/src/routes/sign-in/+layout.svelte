<script lang="ts">
	import { t } from '$lib/i18n/i18n.svelte.js';

	let { children } = $props();
</script>

<!-- Unauthenticated shell: one calm centered column, nothing else. -->
<div class="flex min-h-dvh flex-col items-center px-4 pt-[max(4rem,12vh)] pb-16">
	<header class="text-center">
		<p class="text-2xl font-semibold tracking-tight text-ink">{t('app.name')}</p>
		<p class="mt-1 text-sm text-ink-muted">{t('signin.brand.tagline')}</p>
	</header>
	<main class="mt-10 w-full max-w-sm">
		{@render children()}
	</main>
</div>
