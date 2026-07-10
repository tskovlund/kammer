import type { Instance } from '$lib/instances/types.js';

/**
 * Translates a push payload's absolute link (built server-side by
 * `Kammer.Notifications.NotificationEmail.target_url/2`, e.g.
 * `https://instance.example/c/{community}/g/{group}` or
 * `.../c/{community}/events/{id}` — still the LiveView URL shape, ADR
 * 0024) into the matching in-PWA client-side route
 * (`/i/{instanceId}/c/{community}/g/{group}` or `.../e/{id}`) — the
 * "right account/community" a notification click should land on in this
 * multi-instance client (issue #186).
 *
 * The result never includes the app's base path (`/app`) — callers
 * prefix that themselves, so this stays a pure string-in/string-out
 * function usable from both the service worker and the page.
 *
 * Returns `null` when the URL doesn't belong to any added instance (the
 * account was since removed) or doesn't match a known link shape (a
 * future notification kind this client doesn't understand yet) —
 * callers fall back to opening Home.
 *
 * Known limitation: if the same instance is added twice under different
 * accounts (two `Instance` entries sharing a `baseUrl` origin), this
 * can't tell which account a push was meant for — the payload carries no
 * user-identifying field — and resolves to whichever entry comes first.
 * Rare enough (two accounts on one server, both subscribed to push) not
 * to block on; worth a follow-up if it turns out to matter in practice.
 */
export function resolveNotificationPath(rawUrl: string, instances: Instance[]): string | null {
	let url: URL;
	try {
		url = new URL(rawUrl);
	} catch {
		return null;
	}

	const instance = instances.find((candidate) => {
		try {
			return new URL(candidate.baseUrl).origin === url.origin;
		} catch {
			return false;
		}
	});
	if (!instance) return null;

	const segments = url.pathname.split('/').filter(Boolean);
	if (segments.length !== 4 || segments[0] !== 'c') return null;
	const [, community, kind, id] = segments;
	if (!community || !id) return null;

	if (kind === 'g') return `/i/${instance.id}/c/${community}/g/${id}`;
	if (kind === 'events') return `/i/${instance.id}/c/${community}/e/${id}`;
	return null;
}
