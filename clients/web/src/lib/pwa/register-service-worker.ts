import { base } from '$app/paths';
import { dev } from '$app/environment';

const SERVICE_WORKER_URL = `${base}/service-worker.js`;

/**
 * Registers the app-shell service worker (issue #186) — production builds
 * only, and this function is the *only* registrar: SvelteKit's built-in
 * auto-registration is disabled in vite.config.ts (see the comment there —
 * two registrations of the same URL with different `type` options make the
 * browser treat every page load as a worker update, which reload-loops
 * every controlled page). Skipped in dev on purpose: a worker intercepting
 * fetches during `vite dev` iteration only ever confuses (stale caches
 * shadowing fresh code), and dev needs none of the offline behavior.
 *
 * New versions install silently in the background; they only take over
 * once the tab regains connectivity or becomes visible again — not
 * mid-session — matching the LiveView side's "clients pick up new
 * versions on reconnect" (SPEC §13).
 */
export function registerServiceWorker(): void {
	if (dev) return;
	if (typeof navigator === 'undefined' || !('serviceWorker' in navigator)) return;

	// The service worker's `activate` handler calls `clients.claim()`
	// unconditionally, which fires `controllerchange` even on the very
	// first-ever registration (no controller -> this page's new one) —
	// not just on a later version replacing an earlier one. Reloading on
	// that first transition would surprise-refresh every fresh session
	// (every e2e test gets an uncontrolled browser context, so this is
	// the *common* case there, not an edge case) for no reason: nothing
	// changed underneath an uncontrolled page. Only reload when this
	// page already had a controller when it loaded — that's the actual
	// "a new version just took over" signal.
	const hadControllerAtLoad = Boolean(navigator.serviceWorker.controller);
	let reloading = false;
	navigator.serviceWorker.addEventListener('controllerchange', () => {
		if (!hadControllerAtLoad || reloading) return;
		reloading = true;
		window.location.reload();
	});

	void navigator.serviceWorker
		.register(SERVICE_WORKER_URL, { type: 'module' })
		.then((registration) => {
			function checkForUpdate(): void {
				void registration.update();
			}
			window.addEventListener('online', checkForUpdate);
			document.addEventListener('visibilitychange', () => {
				if (document.visibilityState === 'visible') checkForUpdate();
			});

			registration.addEventListener('updatefound', () => {
				const installing = registration.installing;
				if (!installing) return;
				installing.addEventListener('statechange', () => {
					// Only skip-waiting when this is an *update* over an existing
					// controller — the very first install has no session to avoid
					// interrupting, and no controller yet to trigger a reload from.
					if (installing.state === 'installed' && navigator.serviceWorker.controller) {
						installing.postMessage('SKIP_WAITING');
					}
				});
			});
		});
}
