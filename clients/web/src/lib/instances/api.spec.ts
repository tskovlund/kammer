import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	InstanceApiError,
	exchangeAndAddInstance,
	fetchInstanceStatus,
	passkeySignInAndAddInstance,
	probeInstance,
	requestLink,
	revokeAndRemoveInstance
} from './api';
import { dropSocket } from '$lib/realtime/registry.svelte.js';
import { instanceStore } from './store';
import { fakeLocalStorage } from './test-support';
import { getPasskeyAssertion } from './webauthn';

// The browser ceremony (`navigator.credentials.get` + base64url marshaling)
// is exercised in webauthn.spec.ts; here it's a seam so these tests pin the
// API orchestration around it — challenge, assert, verify, store.
vi.mock('./webauthn', () => ({ getPasskeyAssertion: vi.fn() }));

// The socket registry is a seam too: the manager's teardown behaviour lives
// in manager.spec.ts (the registry itself is thin glue); these tests pin
// that removing an instance — sign-out or replacement — always drops its
// socket.
vi.mock('$lib/realtime/registry.svelte.js', () => ({ dropSocket: vi.fn() }));

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

// openapi-fetch may hand the underlying fetch either (url, init) or a single
// Request it constructed — normalize both so a test can read the sent body.
function sentRequest(call: [input: RequestInfo | URL, init?: RequestInit]): Request {
	const [input, init] = call;
	return input instanceof Request ? input : new Request(String(input), init);
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

	it('rejects a server that answers 200 JSON without a Kammer shape', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ hello: 'world' }));

		await expect(probeInstance('https://not-kammer.example.com')).rejects.toThrow(
			"doesn't look like a Kammer instance"
		);
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

describe('fetchInstanceStatus', () => {
	beforeEach(() => {
		vi.stubGlobal('fetch', vi.fn());
	});
	afterEach(() => vi.unstubAllGlobals());

	const instance = {
		id: 'i1',
		baseUrl: 'https://kammer.example.com',
		instanceName: 'Example',
		deviceToken: 'token-1',
		user: { id: 'u1', email: 'a@example.com', displayName: 'Alice' },
		addedAt: '2026-01-01T00:00:00Z'
	};

	it('returns the version and the per-viewer operator flag', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ instance_name: 'Example Club', version: '0.1.0-dev', instance_operator: true })
		);
		await expect(fetchInstanceStatus(instance)).resolves.toEqual({
			version: '0.1.0-dev',
			instanceOperator: true
		});

		// The read must carry the device token — instance_operator is
		// per-viewer, and a regression to the tokenless client would
		// silently report false forever.
		const request = vi.mocked(fetch).mock.calls[0]?.[0] as Request;
		expect(request.headers.get('authorization')).toBe('Bearer token-1');
	});

	it('returns a safe default shape instead of throwing when the instance is unreachable', async () => {
		vi.mocked(fetch).mockRejectedValueOnce(new TypeError('Failed to fetch'));
		await expect(fetchInstanceStatus(instance)).resolves.toEqual({
			version: null,
			instanceOperator: false
		});
	});
});

describe('requestLink', () => {
	beforeEach(() => {
		vi.stubGlobal('fetch', vi.fn());
	});
	afterEach(() => vi.unstubAllGlobals());

	it('POSTs the email to the request-link endpoint of the given instance', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ status: 'sent' }));

		await requestLink('https://kammer.example.com', 'a@example.com');

		// openapi-fetch may hand the underlying fetch either (url, init) or a
		// single Request it constructed — normalize both shapes.
		const [input, init] = vi.mocked(fetch).mock.calls[0];
		const request =
			input instanceof Request ? input : new Request(String(input), init as RequestInit);
		expect(request.url).toBe('https://kammer.example.com/api/v1/auth/request-link');
		expect(request.method).toBe('POST');
		expect(await request.json()).toEqual({ email: 'a@example.com' });
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
		const oldId = instanceStore.list()[0].id;
		await exchangeAndAddInstance('https://kammer.example.com', 'magic-token-2', 'Example Club');

		const instances = instanceStore.list();
		expect(instances).toHaveLength(1);
		expect(instances[0].deviceToken).toBe('new-token');

		// Replacement is removal of the old entry: its id is discarded, so
		// its socket must be dropped now or no teardown can ever reach it.
		expect(dropSocket).toHaveBeenCalledWith(oldId);
	});
});

describe('passkeySignInAndAddInstance', () => {
	const assertion = {
		credential_id: 'cred',
		authenticator_data: 'authdata',
		signature: 'sig',
		client_data_json: 'cdj'
	};

	beforeEach(() => {
		vi.stubGlobal('localStorage', fakeLocalStorage());
		instanceStore.clear();
		vi.stubGlobal('fetch', vi.fn());
		vi.mocked(getPasskeyAssertion).mockReset();
	});
	afterEach(() => vi.unstubAllGlobals());

	it('runs the challenge → assert → verify ceremony and adds the instance', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(
				jsonResponse({ challenge: 'chal', challenge_token: 'ctok', rp_id: 'kammer.example.com' })
			)
			.mockResolvedValueOnce(
				jsonResponse({
					device_token: 'device-token-123',
					user: { id: 'user-1', email: 'a@example.com', display_name: 'Alice' }
				})
			);
		vi.mocked(getPasskeyAssertion).mockResolvedValueOnce(assertion);

		const instance = await passkeySignInAndAddInstance(
			'https://kammer.example.com',
			'Example Club',
			'My iPhone'
		);

		// The browser was asked to sign the exact challenge + rp_id the
		// server minted — not values invented client-side.
		expect(getPasskeyAssertion).toHaveBeenCalledWith('chal', 'kammer.example.com');

		// Verify echoes the opaque challenge_token verbatim and carries the
		// assertion fields plus the device name.
		const verify = sentRequest(vi.mocked(fetch).mock.calls[1]);
		expect(verify.url).toBe('https://kammer.example.com/api/v1/auth/passkey/verify');
		expect(await verify.json()).toEqual({
			challenge_token: 'ctok',
			device_name: 'My iPhone',
			credential_id: 'cred',
			authenticator_data: 'authdata',
			signature: 'sig',
			client_data_json: 'cdj'
		});

		expect(instance.deviceToken).toBe('device-token-123');
		expect(instance.instanceName).toBe('Example Club');
		expect(instanceStore.list()).toHaveLength(1);
	});

	it('collapses a server-rejected assertion into the same neutral failure, storing nothing', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(
				jsonResponse({ challenge: 'chal', challenge_token: 'ctok', rp_id: 'kammer.example.com' })
			)
			.mockResolvedValueOnce(new Response('unauthorized', { status: 401 }));
		vi.mocked(getPasskeyAssertion).mockResolvedValueOnce(assertion);

		// Same message as the browser-yields-nothing case below — no oracle
		// for which passkeys or accounts exist, mirroring the server's
		// uniform 401.
		await expect(
			passkeySignInAndAddInstance('https://kammer.example.com', 'Example Club')
		).rejects.toThrow('That passkey sign-in did not work.');
		expect(instanceStore.list()).toEqual([]);
	});

	it('aborts before verifying when the browser yields no credential', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ challenge: 'chal', challenge_token: 'ctok', rp_id: 'kammer.example.com' })
		);
		vi.mocked(getPasskeyAssertion).mockResolvedValueOnce(null);

		await expect(
			passkeySignInAndAddInstance('https://kammer.example.com', 'Example Club')
		).rejects.toThrow('That passkey sign-in did not work.');
		// Only the challenge went out — with no assertion there is nothing to
		// verify, and nothing is stored.
		expect(fetch).toHaveBeenCalledTimes(1);
		expect(instanceStore.list()).toEqual([]);
	});

	it('collapses a dismissed prompt (a thrown ceremony) into the same neutral failure', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ challenge: 'chal', challenge_token: 'ctok', rp_id: 'kammer.example.com' })
		);
		// Cancelling the OS prompt *rejects* navigator.credentials.get, so it
		// leaves getPasskeyAssertion as a thrown DOMException — a different
		// mechanism than the explicit sentinel throws, neutralized only by
		// guardNetworkError's catch. It must still reach the one neutral
		// message and store nothing (no leak of the raw cancel reason).
		vi.mocked(getPasskeyAssertion).mockRejectedValueOnce(
			new DOMException('The operation was cancelled.', 'NotAllowedError')
		);

		await expect(
			passkeySignInAndAddInstance('https://kammer.example.com', 'Example Club')
		).rejects.toThrow('That passkey sign-in did not work.');
		expect(fetch).toHaveBeenCalledTimes(1);
		expect(instanceStore.list()).toEqual([]);
	});

	it('fails neutrally without touching the authenticator when the challenge cannot be minted', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(new Response('nope', { status: 500 }));

		await expect(
			passkeySignInAndAddInstance('https://kammer.example.com', 'Example Club')
		).rejects.toThrow('That passkey sign-in did not work.');
		// A challenge that never arrived must not raise an OS prompt — the
		// ceremony is short-circuited before the authenticator is touched.
		expect(getPasskeyAssertion).not.toHaveBeenCalled();
		expect(instanceStore.list()).toEqual([]);
	});
});

describe('revokeAndRemoveInstance', () => {
	beforeEach(() => {
		vi.stubGlobal('localStorage', fakeLocalStorage());
		instanceStore.clear();
		vi.stubGlobal('fetch', vi.fn());
		vi.mocked(dropSocket).mockClear();
	});
	afterEach(() => vi.unstubAllGlobals());

	const instance = {
		id: 'instance-1',
		baseUrl: 'https://kammer.example.com',
		instanceName: 'Example',
		deviceToken: 'token-1',
		user: { id: 'user-1', email: 'a@example.com', displayName: null },
		addedAt: '2026-01-01T00:00:00Z'
	};

	it('revokes the token, removes the instance, and tears down its socket', async () => {
		instanceStore.add(instance);
		vi.mocked(fetch).mockResolvedValueOnce(new Response(null, { status: 204 }));

		await revokeAndRemoveInstance('instance-1');

		// The revoke itself must go out, with the dying token as credential.
		const revoke = sentRequest(vi.mocked(fetch).mock.calls[0]);
		expect(revoke.method).toBe('DELETE');
		expect(revoke.url).toBe('https://kammer.example.com/api/v1/auth/device-token');
		expect(revoke.headers.get('authorization')).toBe('Bearer token-1');

		expect(instanceStore.list()).toEqual([]);
		// Without the teardown the manager would hold the revoked token's
		// socket open until a reconnect 401s.
		expect(dropSocket).toHaveBeenCalledWith('instance-1');
	});

	it('removes the instance locally, socket included, even if the revoke call fails', async () => {
		instanceStore.add(instance);
		vi.mocked(fetch).mockRejectedValueOnce(new Error('network down'));

		await revokeAndRemoveInstance('instance-1');

		expect(instanceStore.list()).toEqual([]);
		expect(dropSocket).toHaveBeenCalledWith('instance-1');
	});

	it('is a no-op for an unknown instance id', async () => {
		await expect(revokeAndRemoveInstance('missing')).resolves.toBeUndefined();
		expect(fetch).not.toHaveBeenCalled();
	});
});
