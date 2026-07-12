import { afterEach, describe, expect, it, vi } from 'vitest';
import { base64UrlToBytes, bytesToBase64Url, createPasskey, getPasskeyAssertion } from './webauthn';

describe('base64url encoding', () => {
	it('encodes to the unpadded, URL-safe alphabet WebAuthn puts on the wire', () => {
		// [0xfb, 0xff, 0xbf] is "+/+/" in the standard alphabet — the exact
		// bytes that expose a `+`/`/` leak or stray `=` padding.
		expect(bytesToBase64Url(new Uint8Array([0xfb, 0xff, 0xbf]).buffer)).toBe('-_-_');
		expect(bytesToBase64Url(new Uint8Array([6]).buffer)).toBe('Bg');
	});

	it('round-trips arbitrary bytes back through decode', () => {
		const bytes = new Uint8Array([0xfb, 0xff, 0xbf, 0x00, 0x10]);
		expect(Array.from(base64UrlToBytes(bytesToBase64Url(bytes.buffer)))).toEqual(Array.from(bytes));
	});
});

describe('getPasskeyAssertion', () => {
	afterEach(() => vi.unstubAllGlobals());

	it('drives a usernameless assertion and marshals it into the verify fields', async () => {
		const get = vi.fn().mockResolvedValue({
			rawId: new Uint8Array([1, 2, 3]).buffer,
			response: {
				authenticatorData: new Uint8Array([4, 5]).buffer,
				signature: new Uint8Array([6]).buffer,
				clientDataJSON: new Uint8Array([7, 8, 9]).buffer
			}
		});
		vi.stubGlobal('navigator', { credentials: { get } });

		const result = await getPasskeyAssertion('chal', 'kammer.example.com');

		// Usernameless (ADR 0018): no `allowCredentials`, so the browser
		// offers whatever resident passkeys it holds — the account is
		// identified by the credential, never enumerated. The server's
		// challenge is signed verbatim.
		const options = get.mock.calls[0][0].publicKey;
		expect(options.allowCredentials).toBeUndefined();
		expect(options.rpId).toBe('kammer.example.com');
		expect(options.userVerification).toBe('preferred');
		expect(options.timeout).toBe(60_000);
		expect(Array.from(options.challenge as Uint8Array)).toEqual(
			Array.from(base64UrlToBytes('chal'))
		);

		// Every buffer comes back base64url-encoded under the field names the
		// verify endpoint reads.
		expect(result).toEqual({
			credential_id: 'AQID',
			authenticator_data: 'BAU',
			signature: 'Bg',
			client_data_json: 'BwgJ'
		});
	});

	it('returns null when the browser produces no credential', async () => {
		vi.stubGlobal('navigator', { credentials: { get: vi.fn().mockResolvedValue(null) } });
		await expect(getPasskeyAssertion('chal', 'rp')).resolves.toBeNull();
	});
});

describe('createPasskey', () => {
	afterEach(() => vi.unstubAllGlobals());

	const options = {
		challenge: 'chal',
		rpId: 'kammer.example.com',
		userId: 'AQID',
		userName: 'a@example.com',
		userDisplayName: 'Alice',
		excludeCredentials: ['Bg']
	};

	it('drives registration and marshals the attestation into the create fields', async () => {
		const create = vi.fn().mockResolvedValue({
			response: {
				attestationObject: new Uint8Array([1, 2, 3]).buffer,
				clientDataJSON: new Uint8Array([4, 5]).buffer
			}
		});
		vi.stubGlobal('navigator', { credentials: { create } });

		const result = await createPasskey(options);

		const publicKey = create.mock.calls[0][0].publicKey;
		expect(publicKey.rp.id).toBe('kammer.example.com');
		expect(publicKey.rp.name).toBe('Kammer');
		expect(publicKey.authenticatorSelection.userVerification).toBe('preferred');
		expect(publicKey.timeout).toBe(60_000);
		// The server's challenge and the account's user id are decoded from
		// base64url back into the bytes the authenticator signs over.
		expect(Array.from(publicKey.challenge as Uint8Array)).toEqual(
			Array.from(base64UrlToBytes('chal'))
		);
		expect(Array.from(publicKey.user.id as Uint8Array)).toEqual(
			Array.from(base64UrlToBytes('AQID'))
		);
		expect(publicKey.user.name).toBe('a@example.com');
		expect(publicKey.user.displayName).toBe('Alice');
		// Discoverable credential (usernameless sign-in can find it later),
		// ES256 + RS256 — the algorithms Wax verifies.
		expect(publicKey.authenticatorSelection.residentKey).toBe('required');
		expect(publicKey.pubKeyCredParams.map((p: { alg: number }) => p.alg)).toEqual([-7, -257]);
		// Already-registered ids are excluded, decoded from base64url.
		expect(Array.from(publicKey.excludeCredentials[0].id as Uint8Array)).toEqual(
			Array.from(base64UrlToBytes('Bg'))
		);

		expect(result).toEqual({ attestation_object: 'AQID', client_data_json: 'BAU' });
	});

	it('returns null when the browser produces no credential', async () => {
		vi.stubGlobal('navigator', { credentials: { create: vi.fn().mockResolvedValue(null) } });
		await expect(createPasskey(options)).resolves.toBeNull();
	});
});
