import { createApiClient } from '$lib/api/client.js';
import { instanceStore } from './store.js';
import type { Instance } from './types.js';

export class InstanceApiError extends Error {}

/**
 * openapi-fetch's `{ data, error }` only distinguishes success from an
 * HTTP-level error response — a DNS failure, an unreachable host, or a
 * blocked cross-origin request makes the underlying `fetch()` reject
 * instead, and that rejection would otherwise propagate as a raw
 * `TypeError` rather than the `InstanceApiError` every caller expects
 * (this is the single most likely failure mode of "add instance": the
 * user mistypes a URL). Wrap network-level exceptions the same way.
 */
async function guardNetworkError<T>(request: () => Promise<T>, message: string): Promise<T> {
	try {
		return await request();
	} catch (cause) {
		if (cause instanceof InstanceApiError) throw cause;
		throw new InstanceApiError(message, { cause });
	}
}

/**
 * The one call site for the capability-discovery endpoint (RFC 0001):
 * both the add-instance probe and the You page's version line read it.
 * Resolves to the instance metadata, or `null` for any HTTP- or
 * network-level failure and for non-Kammer servers that answer 200
 * JSON on unknown paths (which must not become a stored instance named
 * "undefined", nor show a bogus version) — callers decide whether
 * `null` is fatal.
 */
async function fetchInstanceMetadata(baseUrl: string) {
	try {
		const client = createApiClient(baseUrl);
		const { data, error } = await client.GET('/api/v1/instance');
		if (error || !data || typeof data.instance_name !== 'string' || !data.instance_name) {
			return null;
		}
		return data;
	} catch {
		return null;
	}
}

/**
 * Capability discovery before sign-in: confirms `baseUrl` is a real
 * Kammer instance and surfaces its display name for the add-instance
 * screen, without needing credentials yet.
 */
export async function probeInstance(
	baseUrl: string
): Promise<{ instanceName: string; registrationOpen: boolean }> {
	const data = await fetchInstanceMetadata(baseUrl);
	if (!data) {
		throw new InstanceApiError(`${baseUrl} doesn't look like a Kammer instance.`);
	}
	return {
		instanceName: data.instance_name,
		registrationOpen: data.features.registration === 'open'
	};
}

/**
 * The server's product version for the You page's about line (#204).
 * Best effort by design: `null`, never a thrown error, when the
 * instance can't answer — a version footnote must not break settings.
 */
export async function fetchServerVersion(baseUrl: string): Promise<string | null> {
	const version = (await fetchInstanceMetadata(baseUrl))?.version;
	return typeof version === 'string' && version ? version : null;
}

export async function requestLink(baseUrl: string, email: string): Promise<void> {
	return guardNetworkError(async () => {
		const client = createApiClient(baseUrl);
		const { error } = await client.POST('/api/v1/auth/request-link', {
			body: { email }
		});
		if (error) throw new InstanceApiError('Could not request a sign-in link.');
	}, 'Could not request a sign-in link.');
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
	return guardNetworkError(async () => {
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
	}, 'That sign-in link is invalid or has expired.');
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
