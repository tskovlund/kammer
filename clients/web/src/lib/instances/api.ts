import { createApiClient } from '$lib/api/client.js';
import { ApiError, fail, guard } from '$lib/api/errors.js';
import { clearSnapshots } from '$lib/offline/snapshot-cache.js';
import { unsubscribeFromPush } from '$lib/push/subscription.js';
import { instanceStore } from './store.js';
import type { Instance } from './types.js';
import { getPasskeyAssertion } from './webauthn.js';

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
async function fetchInstanceMetadata(baseUrl: string, deviceToken?: string) {
	try {
		const client = createApiClient(baseUrl, deviceToken);
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
 * The signed-in view of the capability doc for the You page: the
 * server's product version for the about line (#204) and whether this
 * account operates the instance (#259) — the per-viewer
 * `instance_operator` flag that gates the operator links (instance
 * settings/moderation, legal pages), replacing the old
 * probe-the-settings-read-for-a-403 dance. One request serves both.
 * Best effort by design: a safe default shape, never a thrown error,
 * when the instance can't answer — a footnote or a hidden link must
 * not break the You page.
 */
export async function fetchInstanceStatus(
	instance: Instance
): Promise<{ version: string | null; instanceOperator: boolean }> {
	const data = await fetchInstanceMetadata(instance.baseUrl, instance.deviceToken);
	return {
		version: typeof data?.version === 'string' && data.version ? data.version : null,
		instanceOperator: data?.instance_operator ?? false
	};
}

/**
 * This instance's Web Push configuration (issues #186/#251): whether
 * it's enabled server-side and, if so, the raw VAPID public key the
 * browser needs for `PushManager.subscribe`. Best-effort — a disabled
 * shape (`{ enabled: false, vapidPublicKey: null }`), never a thrown
 * error, when the instance can't answer, same stance as
 * `fetchInstanceStatus`.
 */
export async function fetchPushConfig(
	baseUrl: string
): Promise<{ enabled: boolean; vapidPublicKey: string | null }> {
	const features = (await fetchInstanceMetadata(baseUrl))?.features;
	return {
		enabled: features?.web_push ?? false,
		vapidPublicKey: features?.vapid_public_key ?? null
	};
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
 * Creates an account (email + display name, SPEC §4 — no password,
 * SPEC §2) and has the instance email a magic sign-in link, the same
 * passwordless confirmation the sign-in flow uses: callers land on the
 * identical "check your email" step afterwards.
 *
 * Unlike the deliberately neutral sign-in endpoints, `POST
 * /auth/register` answers 422 with changeset details, so a
 * `validation`-kind `ApiError` carries `details` (field →
 * messages); map fields with `registerErrorKeys` below.
 */
export async function registerAccount(
	baseUrl: string,
	params: { email: string; displayName: string }
): Promise<void> {
	return guard(async () => {
		const client = createApiClient(baseUrl);
		const { error, response } = await client.POST('/api/v1/auth/register', {
			body: { email: params.email, display_name: params.displayName }
		});
		if (error) throw fail(error, response, 'Could not create the account.');
	});
}

/**
 * The one registration-error → i18n-key mapping, shared by the two
 * registration forms (sign-in page and invite landing) so the same
 * server answer never reads differently between them. Returns i18n
 * KEYS — the caller translates; server message strings never render.
 */
export function registerErrorKeys(cause: unknown): {
	nameKey: 'register.error.displayName' | null;
	emailKey: 'register.error.email' | null;
	formKey: 'register.error.generic' | 'register.error.rateLimited' | null;
} {
	if (cause instanceof ApiError && cause.kind === 'validation') {
		const nameKey = cause.details.display_name ? 'register.error.displayName' : null;
		const emailKey = cause.details.email ? 'register.error.email' : null;
		return {
			nameKey,
			emailKey,
			formKey: nameKey || emailKey ? null : 'register.error.generic'
		};
	}
	if (cause instanceof ApiError && cause.kind === 'rate_limited') {
		return { nameKey: null, emailKey: null, formKey: 'register.error.rateLimited' };
	}
	return { nameKey: null, emailKey: null, formKey: 'register.error.generic' };
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
		return addExchangedInstance(baseUrl, instanceName, data);
	}, 'That sign-in link is invalid or has expired.');
}

/**
 * Signs in with a resident passkey (issue #260 port 5a, ADR 0018) and
 * adds the instance — the credential-based twin of the magic-link
 * `exchangeAndAddInstance`, landing on the same added-instance state.
 * The server runs the WebAuthn assertion ceremony statelessly across
 * two calls: `/auth/passkey/challenge` mints a challenge (and a signed
 * `challenge_token` that carries the server-side state), the browser
 * signs it via `getPasskeyAssertion`, and `/auth/passkey/verify` checks
 * the assertion and issues the device token. Usernameless — no email is
 * asked for and none is enumerable — so `instanceName` is threaded in
 * from the caller's earlier probe, exactly as the magic-link flow does.
 *
 * Every failure — an unusable challenge, the user dismissing the OS
 * prompt (which rejects inside `getPasskeyAssertion`), a rejected
 * assertion — collapses to one neutral message, matching the server's
 * uniform 401 and giving no oracle for which passkeys exist.
 */
export async function passkeySignInAndAddInstance(
	baseUrl: string,
	instanceName: string,
	deviceName?: string
): Promise<Instance> {
	const failure = 'That passkey sign-in did not work.';
	return guardNetworkError(async () => {
		const client = createApiClient(baseUrl);

		const { data: challenge, error: challengeError } = await client.POST(
			'/api/v1/auth/passkey/challenge'
		);
		if (challengeError || !challenge) throw new InstanceApiError(failure);

		const assertion = await getPasskeyAssertion(challenge.challenge, challenge.rp_id);
		if (!assertion) throw new InstanceApiError(failure);

		const { data, error } = await client.POST('/api/v1/auth/passkey/verify', {
			body: {
				challenge_token: challenge.challenge_token,
				device_name: deviceName,
				...assertion
			}
		});
		if (error || !data) throw new InstanceApiError(failure);

		return addExchangedInstance(baseUrl, instanceName, data);
	}, failure);
}

/**
 * Builds and stores the `Instance` from an exchange/verify response —
 * the shared tail of the two sign-in flows, which return the identical
 * `AuthExchangeResponse` (device token + user). Keeping it here means
 * the stored-instance shape can only ever be defined once.
 */
function addExchangedInstance(
	baseUrl: string,
	instanceName: string,
	data: { device_token: string; user: { id: string; email: string; display_name: string | null } }
): Instance {
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
 *
 * Also unregisters this browser's Web Push subscription, when there is
 * one (issue #186) — best-effort, same as the device-token revoke. Only
 * meaningful when `instance.baseUrl`'s origin is the one currently
 * serving the page: a browser's push subscription belongs to *this*
 * origin, so it can only ever have been created for whichever added
 * instance matches it (see `push/notification-routing.ts`'s doc
 * comment) — signing out of a different, CORS-added instance has no
 * local subscription to remove.
 */
export async function revokeAndRemoveInstance(instanceId: string): Promise<void> {
	const instance = instanceStore.get(instanceId);
	if (!instance) return;

	if (typeof window !== 'undefined') {
		try {
			if (new URL(instance.baseUrl).origin === window.location.origin) {
				await unsubscribeFromPush(instance);
			}
		} catch {
			// Best-effort, same reasoning as the device-token revoke below.
		}
	}

	const client = createApiClient(instance.baseUrl, instance.deviceToken);
	try {
		await client.DELETE('/api/v1/auth/device-token');
	} catch {
		// Best-effort: the local removal below is what actually matters.
	} finally {
		instanceStore.remove(instanceId);
		// The offline snapshots mix data across instances — on a shared
		// device the next signer-in must never inherit them (issue #186).
		clearSnapshots();
	}
}
