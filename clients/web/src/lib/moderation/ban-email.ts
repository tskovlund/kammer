/**
 * Whether `email` is one the instance-ban API will accept on format grounds
 * (issue #276). It mirrors the server's `Kammer.Validation.validate_email_format`
 * exactly, so the ban form can reject a malformed address up front with precise
 * copy. That leaves the server's remaining `email` 422 (the unique constraint)
 * unambiguous: an address accepted here can only fail as *already banned*, never
 * as *malformed* — which is what let the form previously mislabel a bad address
 * as "already banned". Keep in lockstep with the server rule (its `.spec.ts`
 * pins the parity).
 *
 * The server's rule is `~r/\A[^@,;\s\x00-\x1F\x7F]+@[^@,;\s\x00-\x1F\x7F]+\z/`
 * plus `max: 160`: exactly one `@`, a non-empty local and domain part, and no
 * `@ , ;`, whitespace, control character (U+0000–U+001F), space (U+0020), or
 * DEL (U+007F) anywhere. Everything else — a hyphen, a plus, a high/multi-byte
 * character — is allowed. Expressed imperatively to avoid a control-character
 * regex literal.
 */
const MAX_BAN_EMAIL_LENGTH = 160;

export function isBanEmailValid(email: string): boolean {
	if (email.length === 0 || email.length > MAX_BAN_EMAIL_LENGTH) return false;

	// Exactly one `@`, with a non-empty local and domain part.
	const at = email.indexOf('@');
	if (at <= 0 || at !== email.lastIndexOf('@') || at === email.length - 1) return false;

	// No comma, semicolon, whitespace, control character, or DEL anywhere.
	for (const ch of email) {
		const code = ch.codePointAt(0) ?? 0;
		if (code <= 0x20 || code === 0x7f || ch === ',' || ch === ';') return false;
	}

	return true;
}
