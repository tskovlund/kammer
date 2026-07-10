/// <reference lib="webworker" />

// This file runs in the service worker's own global scope, not the page's —
// SvelteKit compiles and emits it separately (issue #186), to
// `service-worker.js` at the PWA's base path (see endpoint.ex's Plug.Static
// `only:` allowlist, which had to learn this filename alongside the SPA's
// hashed build assets).
export {};
declare let self: ServiceWorkerGlobalScope;

// `$app/paths` is not importable in service-worker code —
// `$service-worker` provides `base` itself.
import { base, build, files, version } from '$service-worker';

const CACHE_NAME = `kammer-shell-${version}`;
// The SPA's own document ("index.html") isn't part of `build`/`files` —
// those are Vite's hashed bundle and the static/ directory respectively.
// The shell itself is rendered per-request by KammerWeb.PwaController (any
// unmatched /app/* path), so it has to be precached explicitly by URL.
const SHELL_URL = `${base}/`;
// Only the content-hashed assets are safe to serve cache-first; the shell
// is precached purely as the OFFLINE fallback and must never shadow the
// network while online (it's the installed app's start_url — a redeploy
// has to be visible on the next launch, not after a background update).
const ASSET_URLS = [...build, ...files];
const PRECACHE_URLS = [...ASSET_URLS, SHELL_URL];

self.addEventListener('install', (event) => {
	event.waitUntil(
		(async () => {
			const cache = await caches.open(CACHE_NAME);
			await cache.addAll(PRECACHE_URLS);
		})()
	);
});

self.addEventListener('activate', (event) => {
	event.waitUntil(
		(async () => {
			const keys = await caches.keys();
			await Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key)));
			await self.clients.claim();
		})()
	);
});

// A waiting worker only takes over when the page asks it to (see
// $lib/pwa/register-service-worker.ts) — new versions are picked up on
// reconnect/next-visible, not by yanking the shell out from under an
// active session (SPEC §13's "clients pick up new versions on reconnect"
// spirit, carried over from the LiveView side).
self.addEventListener('message', (event) => {
	if (event.data === 'SKIP_WAITING') self.skipWaiting();
});

/**
 * App-shell caching only (SPEC §14/#137): precached build assets and icons
 * are cache-first (content-hashed, safe forever); the SPA shell and every
 * other request go to the network first so a redeploy is visible
 * immediately, falling back to the cached shell only when the network is
 * unreachable. API requests (same-origin or cross-origin to another added
 * instance) are deliberately never cached here — last-fetched data for
 * offline reading is a separate, app-layer concern ($lib/offline), which
 * keeps this service worker's job legible and leaves API responses always
 * live when a network is reachable (including under the e2e suite).
 */
self.addEventListener('fetch', (event) => {
	const { request } = event;
	if (request.method !== 'GET') return;

	const url = new URL(request.url);
	if (url.origin !== self.location.origin) return;

	event.respondWith(respond(request, url));
});

async function respond(request: Request, url: URL): Promise<Response> {
	const cache = await caches.open(CACHE_NAME);

	if (ASSET_URLS.includes(url.pathname)) {
		const cached = await cache.match(url.pathname);
		if (cached) return cached;
	}

	try {
		const response = await fetch(request);
		// Every unmatched /app/* path answers with the same document
		// (KammerWeb.PwaController's SPA fallback), so any successful
		// navigation is a fresh copy of the shell worth refreshing the
		// offline fallback with — not just a request to `/app/` exactly.
		if (response.ok && request.mode === 'navigate') {
			await cache.put(SHELL_URL, response.clone());
		}
		return response;
	} catch (error) {
		if (request.mode === 'navigate') {
			const shell = await cache.match(SHELL_URL);
			if (shell) return shell;
		}
		throw error;
	}
}

/**
 * Web Push (issue #186): the payload shape is `{title, body, url}`
 * (`Kammer.Notifications.push_payload/4`, server-side) — `url` is an
 * absolute LiveView-side link (`Endpoint.url() <> "/c/..."`). This worker
 * cannot resolve it to an in-PWA route itself (no `localStorage` access in
 * a service worker, and resolving needs the locally added instance list),
 * so it hands the raw URL to a page via `postMessage` (already open) or a
 * `notify` query param (cold open) — see $lib/pwa/notification-landing.ts
 * and the root layout for the client-side half.
 */
self.addEventListener('push', (event) => {
	if (!event.data) return;

	let payload: { title?: unknown; body?: unknown; url?: unknown };
	try {
		payload = event.data.json();
	} catch {
		return;
	}

	const title = typeof payload.title === 'string' && payload.title ? payload.title : 'Kammer';
	const body = typeof payload.body === 'string' ? payload.body : undefined;
	const url = typeof payload.url === 'string' ? payload.url : undefined;

	event.waitUntil(
		self.registration.showNotification(title, {
			body,
			icon: `${base}/icons/icon-192.png`,
			badge: `${base}/icons/icon-192.png`,
			data: { url }
		})
	);
});

self.addEventListener('notificationclick', (event) => {
	event.notification.close();
	const url = event.notification.data?.url as string | undefined;

	event.waitUntil(
		(async () => {
			const windowClients = await self.clients.matchAll({
				type: 'window',
				includeUncontrolled: true
			});
			const existing = windowClients.find((client) => client.url.startsWith(self.location.origin));

			if (existing) {
				await existing.focus();
				if (url) existing.postMessage({ type: 'notification-click', url });
				return;
			}

			const landing = url ? `${base}/?notify=${encodeURIComponent(url)}` : SHELL_URL;
			await self.clients.openWindow(landing);
		})()
	);
});
