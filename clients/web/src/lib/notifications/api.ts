import { createApiClient } from '$lib/api/client.js';
import { fail, guard } from '$lib/api/errors.js';
import type { Notification } from '$lib/feed/types.js';
import type { Instance } from '$lib/instances/types.js';

export type { Notification };

function client(instance: Instance) {
	return createApiClient(instance.baseUrl, instance.deviceToken);
}

export interface NotificationsPage {
	notifications: Notification[];
	nextCursor: string | null;
}

// A hung (not erroring, just non-responding) instance must not block the
// merged notification list for every other instance — same guard as
// `fetchMergedHome`.
const FETCH_TIMEOUT_MS = 10_000;

export async function fetchNotificationsPage(
	instance: Instance,
	cursor?: string | null
): Promise<NotificationsPage> {
	return guard(async () => {
		const { data, error, response } = await client(instance).GET('/api/v1/notifications', {
			params: { query: cursor ? { after: cursor } : undefined },
			signal: AbortSignal.timeout(FETCH_TIMEOUT_MS)
		});
		if (error || !data) throw fail(error, response, 'Could not load notifications.');
		return { notifications: data.data, nextCursor: data.next_cursor ?? null };
	});
}

export async function markRead(instance: Instance, notificationId: string): Promise<void> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT(
			'/api/v1/notifications/{notification_id}/read',
			{ params: { path: { notification_id: notificationId } } }
		);
		if (error || !data) throw fail(error, response, 'Could not mark this notification read.');
	});
}

export async function markAllRead(instance: Instance): Promise<void> {
	return guard(async () => {
		const { data, error, response } = await client(instance).PUT('/api/v1/notifications/read-all');
		if (error || !data) throw fail(error, response, 'Could not mark notifications read.');
	});
}
