import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	InstanceApiError,
	exchangeAndAddInstance,
	probeInstance,
	requestLink,
	revokeAndRemoveInstance
} from './api';
import { instanceStore } from './store';
import { fakeLocalStorage } from './test-support';

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

describe('probeInstance', () => {
	beforeEach(() => {
		vi.stubGlobal('fetch', vi.fn());
	});
	afterEach(() => vi.unstubAllGlobals());

	it('returns instance metadata for a real Kammer instance', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({
				instance_name: 'Example Club',
				version: '0.1.0',
				api_versions: ['v1'],
				default_locale: 'en',
				features: { guest_rsvp: true, web_push: true, registration: 'open' }
			})
		);

		const result = await probeInstance('https://kammer.example.com');
		expect(result).toEqual({ instanceName: 'Example Club', registrationOpen: true });
	});

	it('throws for a URL that is not a Kammer instance', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(new Response('not found', { status: 404 }));
		await expect(probeInstance('https://not-kammer.example.com')).rejects.toThrow(InstanceApiError);
	});

	it('throws InstanceApiError, not a raw TypeError, when the network request itself fails', async () => {
		vi.mocked(fetch).mockRejectedValueOnce(new TypeError('Failed to fetch'));
		await expect(probeInstance('https://unreachable.example.com')).rejects.toThrow(
			InstanceApiError
		);
	});
});

describe('requestLink', () => {
	beforeEach(() => {
		vi.stubGlobal('fetch', vi.fn());
	});
	afterEach(() => vi.unstubAllGlobals());

	it('resolves on success', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ status: 'sent' }));
		await expect(
			requestLink('https://kammer.example.com', 'a@example.com')
		).resolves.toBeUndefined();
	});
});

describe('exchangeAndAddInstance', () => {
	beforeEach(() => {
		vi.stubGlobal('localStorage', fakeLocalStorage());
		instanceStore.clear();
		vi.stubGlobal('fetch', vi.fn());
	});
	afterEach(() => vi.unstubAllGlobals());

	it('adds the instance to the store on a successful exchange', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({
				device_token: 'device-token-123',
				user: { id: 'user-1', email: 'a@example.com', display_name: 'Alice' }
			})
		);

		const instance = await exchangeAndAddInstance(
			'https://kammer.example.com',
			'magic-token',
			'Example Club'
		);

		expect(instance.deviceToken).toBe('device-token-123');
		expect(instance.instanceName).toBe('Example Club');
		expect(instanceStore.list()).toHaveLength(1);
		expect(fetch).toHaveBeenCalledTimes(1);
	});

	it('throws without adding anything on an invalid token', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(new Response('unauthorized', { status: 401 }));
		await expect(
			exchangeAndAddInstance('https://kammer.example.com', 'bad-token', 'Example Club')
		).rejects.toThrow(InstanceApiError);
		expect(instanceStore.list()).toEqual([]);
	});

	it('throws InstanceApiError, not a raw TypeError, on a network-level failure', async () => {
		vi.mocked(fetch).mockRejectedValueOnce(new TypeError('Failed to fetch'));
		await expect(
			exchangeAndAddInstance('https://kammer.example.com', 'magic-token', 'Example Club')
		).rejects.toThrow(InstanceApiError);
		expect(instanceStore.list()).toEqual([]);
	});

	it('re-authenticating to an already-added instance replaces it instead of duplicating it', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(
				jsonResponse({
					device_token: 'old-token',
					user: { id: 'user-1', email: 'a@example.com', display_name: 'Alice' }
				})
			)
			.mockResolvedValueOnce(
				jsonResponse({
					device_token: 'new-token',
					user: { id: 'user-1', email: 'a@example.com', display_name: 'Alice' }
				})
			);

		await exchangeAndAddInstance('https://kammer.example.com', 'magic-token-1', 'Example Club');
		await exchangeAndAddInstance('https://kammer.example.com', 'magic-token-2', 'Example Club');

		const instances = instanceStore.list();
		expect(instances).toHaveLength(1);
		expect(instances[0].deviceToken).toBe('new-token');
	});
});

describe('revokeAndRemoveInstance', () => {
	beforeEach(() => {
		vi.stubGlobal('localStorage', fakeLocalStorage());
		instanceStore.clear();
		vi.stubGlobal('fetch', vi.fn());
	});
	afterEach(() => vi.unstubAllGlobals());

	it('removes the instance locally even if the revoke call fails', async () => {
		instanceStore.add({
			id: 'instance-1',
			baseUrl: 'https://kammer.example.com',
			instanceName: 'Example',
			deviceToken: 'token-1',
			user: { id: 'user-1', email: 'a@example.com', displayName: null },
			addedAt: '2026-01-01T00:00:00Z'
		});
		vi.mocked(fetch).mockRejectedValueOnce(new Error('network down'));

		await revokeAndRemoveInstance('instance-1');

		expect(instanceStore.list()).toEqual([]);
	});

	it('is a no-op for an unknown instance id', async () => {
		await expect(revokeAndRemoveInstance('missing')).resolves.toBeUndefined();
		expect(fetch).not.toHaveBeenCalled();
	});
});
