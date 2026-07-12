import { createApiClient } from '$lib/api/client.js';
import { fail, guard } from '$lib/api/errors.js';
import type { Instance } from '$lib/instances/types.js';

/**
 * Registers this browser's Web Push subscription with one instance (issue
 * #173's endpoint, #186's client). Idempotent server-side (upsert on
 * `[user_id, endpoint]`) — safe to call again, e.g. after re-subscribing
 * with a rotated key.
 */
export async function registerPushSubscription(
	instance: Instance,
	subscription: PushSubscriptionJSON
): Promise<void> {
	return guard(async () => {
		const { error, response } = await createApiClient(instance.baseUrl, instance.deviceToken).POST(
			'/api/v1/push-subscriptions',
			{
				body: {
					endpoint: subscription.endpoint,
					keys: {
						p256dh: subscription.keys?.p256dh,
						auth: subscription.keys?.auth
					}
				}
			}
		);
		if (error) throw fail(error, response, 'Could not enable push notifications.');
	});
}

/**
 * Removes this browser's subscription from one instance — called on
 * sign-out (best-effort there, see `revokeAndRemoveInstance`) and when the
 * user turns push off explicitly. The server treats the delete as
 * idempotent, so a subscription that's already gone isn't an error.
 */
export async function deletePushSubscription(instance: Instance, endpoint: string): Promise<void> {
	return guard(async () => {
		const { error, response } = await createApiClient(
			instance.baseUrl,
			instance.deviceToken
		).DELETE('/api/v1/push-subscriptions', {
			params: { query: { endpoint } }
		});
		if (error) throw fail(error, response, 'Could not disable push notifications.');
	});
}
