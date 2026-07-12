import { afterEach, describe, expect, it, vi } from 'vitest';
import { base64UrlToBytes, bytesToBase64Url, getPasskeyAssertion } from './webauthn';

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
