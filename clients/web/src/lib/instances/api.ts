import { createApiClient } from '$lib/api/client.js';
import { instanceStore } from './store.js';
import type { Instance } from './types.js';

export class InstanceApiError extends Error {}

/**
 * Capability discovery (RFC 0001) before sign-in: confirms `baseUrl` is a
 * real Kammer instance and surfaces its display name for the add-instance
 * screen, without needing credentials yet.
 */
export async function probeInstance(
	baseUrl: string
): Promise<{ instanceName: string; registrationOpen: boolean }> {
	const client = createApiClient(baseUrl);
	const { data, error } = await client.GET('/api/v1/instance');
	if (error || !data) {
		throw new InstanceApiError(`${baseUrl} doesn't look like a Kammer instance.`);
	}
	return {
		instanceName: data.instance_name,
		registrationOpen: data.features.registration === 'open'
	};
}

export async function requestLink(baseUrl: string, email: string): Promise<void> {
	const client = createApiClient(baseUrl);
	const { error } = await client.POST('/api/v1/auth/request-link', {
		body: { email }
	});
	if (error) throw new InstanceApiError('Could not request a sign-in link.');
}

/**
 * Trades the magic-link token for a device token and adds the instance to
 * the store — the point at which "signing in" becomes "an added instance"
 * in the multi-instance session-holder model (ADR 0001).
 *
 * `instanceName` is threaded in from the caller's earlier `probeInstance`
 * call (the add-instance flow always probes before requesting a sign-in
 * link) rather than re-fetched here: re-probing after a successful
 * exchange would cost a second network round-trip, and — worse — would
 * discard the just-issued, already-valid device token if that second call
 * happened to fail.
 */
export async function exchangeAndAddInstance(
	baseUrl: string,
	magicToken: string,
	instanceName: string,
	deviceName?: string
): Promise<Instance> {
	const client = createApiClient(baseUrl);
	const { data, error } = await client.POST('/api/v1/auth/exchange', {
		body: { magic_token: magicToken, device_name: deviceName }
	});
	if (error || !data) {
		throw new InstanceApiError('That sign-in link is invalid or has expired.');
	}

	const instance: Instance = {
		id: crypto.randomUUID(),
		baseUrl,
		instanceName,
		deviceToken: data.device_token,
		user: {
			id: data.user.id,
			email: data.user.email,
			displayName: data.user.display_name
		},
		addedAt: new Date().toISOString()
	};

	instanceStore.add(instance);
	return instance;
}

/**
 * Revokes the device token server-side, then removes the instance
 * locally regardless of whether the revoke call succeeds — a signed-out
 * instance shouldn't stay stuck in the list because its server is
 * unreachable.
 */
export async function revokeAndRemoveInstance(instanceId: string): Promise<void> {
	const instance = instanceStore.get(instanceId);
	if (!instance) return;

	const client = createApiClient(instance.baseUrl, instance.deviceToken);
	try {
		await client.DELETE('/api/v1/auth/device-token');
	} catch {
		// Best-effort: the local removal below is what actually matters.
	} finally {
		instanceStore.remove(instanceId);
	}
}
