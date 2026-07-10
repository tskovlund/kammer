<script lang="ts">
	import { onMount } from 'svelte';
	import './layout.css';
	import { goto } from '$app/navigation';
	import { base, resolve } from '$app/paths';
	import { page } from '$app/state';
	import favicon from '$lib/assets/favicon.svg';
	import { i18n } from '$lib/i18n/i18n.svelte.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { resolveNotificationPath } from '$lib/push/notification-routing.js';
	import { registerServiceWorker } from '$lib/pwa/register-service-worker.js';

	let { children } = $props();

	// Keep <html lang> in step with the active locale (the pre-hydration
	// script in app.html only covers a persisted override at first paint).
	$effect(() => {
		document.documentElement.lang = i18n.locale;
	});

	/**
	 * A notification click's target — resolved here, not in the service
	 * worker, because resolving needs the added-instance list, which is
	 * only readable from a page (service workers have no `localStorage`
	 * access). Two delivery paths from service-worker.ts's
	 * `notificationclick` handler land here: a `notify` query param for a
	 * cold open (`clients.openWindow`), or a `postMessage` for a window
	 * already open (`client.postMessage` after focusing it).
	 *
	 * `resolveNotificationPath`'s result is a runtime-computed string, not
	 * a template literal written at this call site, so `resolve()` can't
	 * type-check it against the generated route table the way a literal
	 * `resolve(\`/i/${id}/...\`)` elsewhere in this app does — it's
	 * base-prefixed by hand instead and handed straight to `goto`, which
	 * (unlike `resolve`) accepts any string.
	 */
	function landOnNotification(url: string): void {
		const path = resolveNotificationPath(url, instances.list);
		// eslint-disable-next-line svelte/no-navigation-without-resolve -- see doc comment above
		void goto(path ? `${base}${path}` : resolve('/'));
	}

	onMount(() => {
		registerServiceWorker();

		const notify = page.url.searchParams.get('notify');
		if (notify) landOnNotification(notify);

		if (typeof navigator === 'undefined' || !('serviceWorker' in navigator)) return;
		function onMessage(event: MessageEvent): void {
			if (event.data?.type === 'notification-click' && typeof event.data.url === 'string') {
				landOnNotification(event.data.url);
			}
		}
		navigator.serviceWorker.addEventListener('message', onMessage);
		return () => navigator.serviceWorker.removeEventListener('message', onMessage);
	});
</script>

<svelte:head><link rel="icon" href={favicon} /></svelte:head>
{@render children()}
