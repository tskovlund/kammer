import type { Notification } from '$lib/feed/types.js';

/**
 * Typed as the two route shapes (not `string`) so callers can hand the
 * result straight to `resolve()`, which type-checks against the generated
 * route table.
 */
export type NotificationTarget =
	`/i/${string}/c/${string}/e/${string}` | `/i/${string}/c/${string}/g/${string}`;

/**
 * The in-PWA route a notification tap lands on — the same instance-aware
 * shapes `resolveNotificationPath` ($lib/push/notification-routing.ts)
 * resolves push links to, but built from the API payload's structured
 * fields (community/group slugs + `event_id`) instead of parsing a URL:
 * `/i/{instanceId}/c/{community}/e/{event}` for event notifications,
 * `/i/{instanceId}/c/{community}/g/{group}` for everything post/comment
 * shaped (the feed screen is where the post lives — same tap-through
 * target `NotificationLive.Index` uses).
 *
 * Like the push resolver, the result never includes the app's base path;
 * callers wrap it in `resolve()`. Returns `null` when the payload carries
 * no navigable target — callers fall back to Home.
 */
export function notificationTarget(
	notification: Notification,
	instanceId: string
): NotificationTarget | null {
	const community = notification.community;
	if (!community) return null;
	const base = `/i/${instanceId}/c/${community.slug}` as const;
	if (notification.event_id) return `${base}/e/${notification.event_id}`;
	if (notification.group) return `${base}/g/${notification.group.slug}`;
	return null;
}
