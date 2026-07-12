/**
 * The browser half of passkey sign-in (issue #260 port 5a, ADR 0018).
 * The server runs a usernameless WebAuthn assertion ceremony statelessly
 * (`/auth/passkey/challenge` → `/auth/passkey/verify`); this drives
 * `navigator.credentials.get` in between and marshals the assertion into
 * the base64url fields the verify endpoint reads. Kept out of the API
 * module so the ceremony is unit-testable on its own.
 */

/** The assertion fields, base64url-encoded, ready for `/auth/passkey/verify`. */
export interface PasskeyAssertion {
	credential_id: string;
	authenticator_data: string;
	signature: string;
	client_data_json: string;
}

/**
 * Whether this browser can run a WebAuthn assertion at all. The sign-in
 * page hides the passkey affordance when this is false rather than
 * offering a button that can only fail.
 */
export function isPasskeySupported(): boolean {
	return (
		typeof window !== 'undefined' &&
		typeof window.PublicKeyCredential !== 'undefined' &&
		typeof navigator !== 'undefined' &&
		typeof navigator.credentials?.get === 'function'
	);
}

/**
 * Whether this browser can *register* a WebAuthn credential. The device
 * page hides the "Add a passkey" affordance when this is false, the same
 * way sign-in hides its assertion button.
 */
export function isPasskeyRegistrationSupported(): boolean {
	return (
		typeof window !== 'undefined' &&
		typeof window.PublicKeyCredential !== 'undefined' &&
		typeof navigator !== 'undefined' &&
		typeof navigator.credentials?.create === 'function'
	);
}

/**
 * Whether `baseUrl` is served from the very origin this PWA is running
 * on. WebAuthn ties every ceremony to the server-minted `rp_id` (the
 * instance's host), which the browser requires to equal the page's own
 * origin — so a cross-origin instance (the "add another community" case)
 * could only ever throw `SecurityError`. Both passkey affordances
 * (sign-in and enrollment) gate on this so they never offer a control
 * that can only fail. Same origin-binding as this browser's push
 * subscription (see `instances/api.ts`'s `revokeAndRemoveInstance`).
 */
export function sameOriginInstance(baseUrl: string): boolean {
	if (!baseUrl || typeof window === 'undefined') return false;
	try {
		return new URL(baseUrl).origin === window.location.origin;
	} catch {
		return false;
	}
}

/**
 * Runs the assertion ceremony for a usernameless sign-in: no
 * `allowCredentials`, so the browser offers whatever resident passkeys
 * it holds for this instance's `rpId`, and the credential itself
 * identifies the account (no email asked, no enumeration surface — the
 * same shape as the server flow). Returns the encoded assertion, or
 * `null` when the browser yields no credential. Throws whatever
 * `navigator.credentials.get` throws (e.g. the user dismissing the
 * prompt) — the caller collapses that into one neutral failure.
 */
export async function getPasskeyAssertion(
	challenge: string,
	rpId: string
): Promise<PasskeyAssertion | null> {
	const credential = await navigator.credentials.get({
		publicKey: {
			challenge: base64UrlToBytes(challenge),
			rpId,
			userVerification: 'preferred',
			// Match the ported LiveView ceremony (advisory; browser-clamped).
			timeout: 60_000
		}
	});

	// Narrow by cast, not `instanceof`: the DOM WebAuthn constructors
	// aren't defined under jsdom (tests), and a resident-key assertion is
	// the only thing this call can return anyway.
	const assertion = credential as
		(PublicKeyCredential & { response: AuthenticatorAssertionResponse }) | null;
	if (!assertion?.rawId || !assertion.response) return null;

	const { response } = assertion;
	return {
		credential_id: bytesToBase64Url(assertion.rawId),
		authenticator_data: bytesToBase64Url(response.authenticatorData),
		signature: bytesToBase64Url(response.signature),
		client_data_json: bytesToBase64Url(response.clientDataJSON)
	};
}

/** The registration options `createPasskey` needs, all base64url where noted. */
export interface PasskeyRegistrationOptions {
	challenge: string;
	rpId: string;
	userId: string;
	userName: string;
	userDisplayName: string;
	excludeCredentials: string[];
}

/** The attestation fields, base64url-encoded, ready for `POST /me/passkeys`. */
export interface PasskeyAttestation {
	attestation_object: string;
	client_data_json: string;
}

/**
 * Runs the registration ceremony for enrolling a new passkey (ADR 0018,
 * issue #260 port 5b). `residentKey: 'required'` makes it a discoverable
 * credential, so the usernameless sign-in ceremony can later find it;
 * `excludeCredentials` stops the authenticator re-enrolling a key the
 * account already holds. Returns the encoded attestation, or `null` when
 * the browser yields no credential. Throws whatever
 * `navigator.credentials.create` throws (e.g. the user dismissing the
 * prompt) — the caller collapses that into one neutral failure, mirroring
 * `getPasskeyAssertion`.
 */
export async function createPasskey(
	options: PasskeyRegistrationOptions
): Promise<PasskeyAttestation | null> {
	const credential = await navigator.credentials.create({
		publicKey: {
			challenge: base64UrlToBytes(options.challenge),
			rp: { id: options.rpId, name: 'Kammer' },
			user: {
				id: base64UrlToBytes(options.userId),
				name: options.userName,
				displayName: options.userDisplayName
			},
			// ES256 and RS256 — the two algorithms Wax verifies server-side.
			pubKeyCredParams: [
				{ type: 'public-key', alg: -7 },
				{ type: 'public-key', alg: -257 }
			],
			authenticatorSelection: { residentKey: 'required', userVerification: 'preferred' },
			excludeCredentials: options.excludeCredentials.map((id) => ({
				type: 'public-key',
				id: base64UrlToBytes(id)
			})),
			timeout: 60_000
		}
	});

	// Narrow by cast, not `instanceof`: the DOM WebAuthn constructors aren't
	// defined under jsdom (tests), and a create() call only ever returns an
	// attestation anyway.
	const attestation = credential as
		(PublicKeyCredential & { response: AuthenticatorAttestationResponse }) | null;
	if (!attestation?.response) return null;

	const { response } = attestation;
	return {
		attestation_object: bytesToBase64Url(response.attestationObject),
		client_data_json: bytesToBase64Url(response.clientDataJSON)
	};
}

/** ArrayBuffer → unpadded base64url (WebAuthn's on-the-wire encoding). */
export function bytesToBase64Url(buffer: ArrayBuffer): string {
	const bytes = new Uint8Array(buffer);
	let binary = '';
	for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
	return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * Unpadded base64url → bytes (the challenge arrives this way). Typed as
 * `Uint8Array<ArrayBuffer>` — not the wider `ArrayBufferLike` default —
 * so it satisfies `BufferSource` for `navigator.credentials.get`'s
 * `challenge` field.
 */
export function base64UrlToBytes(value: string): Uint8Array<ArrayBuffer> {
	const padded = value + '='.repeat((4 - (value.length % 4)) % 4);
	const binary = atob(padded.replace(/-/g, '+').replace(/_/g, '/'));
	const bytes = new Uint8Array(binary.length);
	for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
	return bytes;
}
