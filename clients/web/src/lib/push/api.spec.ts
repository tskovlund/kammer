import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { deletePushSubscription, registerPushSubscription } from './api.js';
import type { Instance } from '$lib/instances/types.js';

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

function fixture(overrides: Partial<Instance> = {}): Instance {
	return {
		id: 'instance-1',
		baseUrl: 'https://kammer.example.com',
		instanceName: 'Example',
		deviceToken: 'token-1',
		user: { id: 'user-1', email: 'a@example.com', displayName: 'Alice' },
		addedAt: '2026-01-01T00:00:00Z',
		...overrides
	};
}

// `PushSubscriptionJSON`'s fields are all optional (the DOM lib type
// covers a subscription that hasn't finished serializing) — pinned to a
// plain `string` here since every test relies on `endpoint` being set.
const endpoint = 'https://push.example.com/subscription-id';
const subscription: PushSubscriptionJSON = {
	endpoint,
	keys: { p256dh: 'p256dh-key', auth: 'auth-key' }
};

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => vi.unstubAllGlobals());

describe('registerPushSubscription', () => {
	it('posts the subscription and resolves on success', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ status: 'subscribed' }, 201));

		await expect(registerPushSubscription(fixture(), subscription)).resolves.toBeUndefined();
		// openapi-fetch calls `fetch(request)` with a single `Request`, not
		// the two-arg `fetch(url, init)` form — its body is a stream, read
		// via `.json()`.
		const [request] = vi.mocked(fetch).mock.calls[0] as [Request];
		expect(await request.json()).toEqual({
			endpoint: subscription.endpoint,
			keys: subscription.keys
		});
	});

	it('surfaces a malformed subscription as a validation PushApiError', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ error: { code: 'invalid_params', message: 'Bad subscription.' } }, 422)
		);

		await expect(registerPushSubscription(fixture(), subscription)).rejects.toMatchObject({
			kind: 'validation',
			status: 422
		});
	});

	it('surfaces a network failure as a network PushApiError', async () => {
		vi.mocked(fetch).mockRejectedValueOnce(new TypeError('fetch failed'));

		await expect(registerPushSubscription(fixture(), subscription)).rejects.toMatchObject({
			kind: 'network'
		});
	});
});

describe('deletePushSubscription', () => {
	it('deletes by endpoint and resolves on success', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ status: 'deleted' }, 200));

		await expect(deletePushSubscription(fixture(), endpoint)).resolves.toBeUndefined();
		const [request] = vi.mocked(fetch).mock.calls[0] as [Request];
		expect(request.url).toContain(encodeURIComponent(endpoint));
	});

	it('surfaces an expired device token as an auth PushApiError', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ error: { code: 'unauthorized', message: 'Expired.' } }, 401)
		);

		await expect(deletePushSubscription(fixture(), endpoint)).rejects.toMatchObject({
			kind: 'auth',
			status: 401
		});
	});
});
