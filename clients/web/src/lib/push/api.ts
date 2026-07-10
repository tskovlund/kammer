import { createApiClient } from '$lib/api/client.js';
import type { Instance } from '$lib/instances/types.js';

export type PushErrorKind = 'auth' | 'forbidden' | 'validation' | 'network' | 'server';

export class PushApiError extends Error {
	readonly kind: PushErrorKind;
	readonly status: number | null;

	constructor(kind: PushErrorKind, message: string, status: number | null = null) {
		super(message);
		this.name = 'PushApiError';
		this.kind = kind;
		this.status = status;
	}
}

function kindForStatus(status: number): PushErrorKind {
	switch (status) {
		case 401:
			return 'auth';
		case 403:
			return 'forbidden';
		case 422:
			return 'validation';
		default:
			return 'server';
	}
}

interface ErrorEnvelope {
	error?: { code?: string; message?: string };
}

function fail(error: unknown, response: Response | undefined, fallback: string): PushApiError {
	const status = response?.status ?? null;
	const kind = status ? kindForStatus(status) : 'server';
	const message = (error as ErrorEnvelope | undefined)?.error?.message ?? fallback;
	return new PushApiError(kind, message, status);
}

async function guard<T>(request: () => Promise<T>): Promise<T> {
	try {
		return await request();
	} catch (cause) {
		if (cause instanceof PushApiError) throw cause;
		throw new PushApiError('network', 'Could not reach this instance.', null);
	}
}

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
