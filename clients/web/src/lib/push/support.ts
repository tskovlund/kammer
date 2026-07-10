/** Whether this browser can hold a Web Push subscription at all. */
export function isPushSupported(): boolean {
	return (
		typeof navigator !== 'undefined' &&
		'serviceWorker' in navigator &&
		typeof window !== 'undefined' &&
		'PushManager' in window
	);
}

/**
 * `PushManager.subscribe`'s `applicationServerKey` wants a raw
 * `Uint8Array`, not the URL-safe base64 string a VAPID public key is
 * normally handed around as — this is the standard conversion (see the
 * Web Push / `web-push` ecosystem's canonical snippet).
 */
export function urlBase64ToUint8Array(base64: string): Uint8Array {
	const padding = '='.repeat((4 - (base64.length % 4)) % 4);
	const normalized = (base64 + padding).replace(/-/g, '+').replace(/_/g, '/');
	const raw = atob(normalized);
	const bytes = new Uint8Array(raw.length);
	for (let i = 0; i < raw.length; i += 1) bytes[i] = raw.charCodeAt(i);
	return bytes;
}
