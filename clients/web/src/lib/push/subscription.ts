import type { Instance } from '$lib/instances/types.js';
import { deletePushSubscription, registerPushSubscription } from './api.js';
import { urlBase64ToUint8Array } from './support.js';

/**
 * Browser-API glue over `push/api.ts` and `push/support.ts` — thin by
 * design (no independently testable logic of its own; `PushManager`
 * doesn't exist under vitest's node or jsdom projects). One active
 * `PushSubscription` exists per service worker registration, which is
 * per browser *origin* — see the notification-routing module's doc
 * comment for why that means push is only ever registerable for the
 * instance whose `baseUrl` origin matches the page you're currently on.
 */

/** The current browser's active push subscription, if any. */
export async function currentSubscription(): Promise<PushSubscription | null> {
	if (!('serviceWorker' in navigator)) return null;
	const registration = await navigator.serviceWorker.ready;
	return registration.pushManager.getSubscription();
}

/**
 * Subscribes this browser to push and registers it with `instance`. Only
 * meaningful when `instance.baseUrl`'s origin matches the page's own
 * origin (enforced by the calling UI, not here) — the browser has no
 * concept of a push subscription for a different origin.
 */
export async function subscribeToPush(instance: Instance, vapidPublicKey: string): Promise<void> {
	const registration = await navigator.serviceWorker.ready;
	const subscription = await registration.pushManager.subscribe({
		userVisibleOnly: true,
		// `Uint8Array`'s default type parameter (`ArrayBufferLike`, which
		// includes `SharedArrayBuffer`) doesn't structurally satisfy
		// `BufferSource` under this project's TypeScript version — the
		// bytes are always backed by a plain `ArrayBuffer` in practice
		// (`urlBase64ToUint8Array` only ever calls `new Uint8Array(n)`).
		applicationServerKey: urlBase64ToUint8Array(vapidPublicKey) as BufferSource
	});
	await registerPushSubscription(instance, subscription.toJSON());
}

/**
 * Unsubscribes this browser from push and best-effort removes it from
 * `instance` server-side — mirrors `revokeAndRemoveInstance`'s
 * best-effort server call: the local unsubscribe is what actually
 * matters to the user, an unreachable server shouldn't block it.
 */
export async function unsubscribeFromPush(instance: Instance): Promise<void> {
	const subscription = await currentSubscription();
	if (!subscription) return;

	const endpoint = subscription.endpoint;
	await subscription.unsubscribe();
	try {
		await deletePushSubscription(instance, endpoint);
	} catch {
		// Best-effort — the subscription is already gone locally.
	}
}
