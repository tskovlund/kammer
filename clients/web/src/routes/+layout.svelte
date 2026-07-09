<script lang="ts">
	import './layout.css';
	import favicon from '$lib/assets/favicon.svg';
	import { i18n } from '$lib/i18n/i18n.svelte.js';

	let { children } = $props();

	// Keep <html lang> in step with the active locale (the pre-hydration
	// script in app.html only covers a persisted override at first paint).
	$effect(() => {
		document.documentElement.lang = i18n.locale;
	});
</script>

<svelte:head><link rel="icon" href={favicon} /></svelte:head>
{@render children()}
