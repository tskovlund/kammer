import { describe, expect, it } from 'vitest';
import { isBanEmailValid } from './ban-email.js';

// Control characters built here rather than written as literals, so this source
// stays plain text while still exercising the bytes the server rejects.
const NUL = String.fromCharCode(0);
const TAB = String.fromCharCode(9);
const DEL = String.fromCharCode(127);

describe('isBanEmailValid (parity with Kammer.Validation.validate_email_format, #276)', () => {
	it('accepts every address the server accepts', () => {
		expect(isBanEmailValid('a@b.com')).toBe(true);
		// A hyphen and a plus tag are allowed — the server forbids only @ , ;
		// whitespace and control chars, not these.
		expect(isBanEmailValid('user.name+tag@sub-domain.example.co')).toBe(true);
		// The server's regex does not require a dot in the domain.
		expect(isBanEmailValid('x@y')).toBe(true);
		// A high/multi-byte (IDN) address matches the server rule — it forbids
		// only ASCII @ , ; whitespace and control chars, so the helper must not
		// reject non-ASCII. (The form's type="email" input blocks IDN natively;
		// this pins the helper's parity so a future stricter edit can't silently
		// diverge from the server.)
		expect(isBanEmailValid('bruger@øl.dk')).toBe(true);
		// The server downcases before validating, so case never affects validity.
		expect(isBanEmailValid('Bruger@Firma.DK')).toBe(true);
		// 160 characters is the server's cap; exactly 160 is accepted.
		const at160 = `${'a'.repeat(154)}@b.com`;
		expect(at160).toHaveLength(160);
		expect(isBanEmailValid(at160)).toBe(true);
	});

	it('rejects every address the server rejects, so an email 422 can only mean already-banned', () => {
		expect(isBanEmailValid('')).toBe(false);
		expect(isBanEmailValid('nope')).toBe(false); // no @
		expect(isBanEmailValid('@b.com')).toBe(false); // empty local part
		expect(isBanEmailValid('a@')).toBe(false); // empty domain part
		expect(isBanEmailValid('a@b@c')).toBe(false); // more than one @
		expect(isBanEmailValid('a,b@c')).toBe(false); // comma
		expect(isBanEmailValid('a;b@c')).toBe(false); // semicolon
		expect(isBanEmailValid('a b@c')).toBe(false); // space
		expect(isBanEmailValid(`a${TAB}@c`)).toBe(false); // tab
		expect(isBanEmailValid(`a${NUL}@c`)).toBe(false); // NUL
		expect(isBanEmailValid(`a${DEL}@c`)).toBe(false); // DEL
		// 161 characters exceeds the server's 160 cap.
		expect(isBanEmailValid(`${'a'.repeat(155)}@b.com`)).toBe(false);
	});
});
