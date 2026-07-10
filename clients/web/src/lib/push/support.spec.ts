import { describe, expect, it } from 'vitest';
import { urlBase64ToUint8Array } from './support.js';

describe('urlBase64ToUint8Array', () => {
	it('decodes a URL-safe base64 VAPID key into raw bytes', () => {
		// "hello" in URL-safe base64, deliberately unpadded (the way VAPID
		// public keys are normally handed out) to exercise the padding fix-up.
		const bytes = urlBase64ToUint8Array('aGVsbG8');

		expect(Array.from(bytes)).toEqual(Array.from(Buffer.from('hello')));
	});

	it('handles the URL-safe "-" and "_" substitutions', () => {
		// Bytes [0xfb, 0xff, 0xbf] base64-encode to "+/+/" in the standard
		// alphabet, "-_-_" in the URL-safe one VAPID keys use.
		const bytes = urlBase64ToUint8Array('-_-_');

		expect(Array.from(bytes)).toEqual([0xfb, 0xff, 0xbf]);
	});
});
