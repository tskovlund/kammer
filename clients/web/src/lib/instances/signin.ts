/**
 * Pure input-parsing helpers for the sign-in flow — separated from the
 * screens so they're unit-testable under vitest's node environment.
 */

/**
 * Normalizes what a person types as "my community's address" into an
 * origin the API client can use: bare hostnames get https://, paths and
 * trailing slashes are dropped. Returns null when it can't be a URL.
 */
export function normalizeInstanceUrl(input: string): string | null {
	const trimmed = input.trim();
	if (!trimmed) return null;
	const withScheme = /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
	try {
		const url = new URL(withScheme);
		if (!url.hostname.includes('.') && url.hostname !== 'localhost') return null;
		return url.origin;
	} catch {
		return null;
	}
}

/**
 * Extracts a magic sign-in token from whatever the user pastes into the
 * "check your email" screen: the full magic-link URL from the email
 * (`…/users/log-in/{token}`), this client's own deep-link form
 * (`…/sign-in/{token}`), or the bare token itself. Returns null when the
 * paste can't contain a token.
 */
export function extractMagicToken(input: string): string | null {
	// Plaintext mail clients and hurried copies drag sentence-final
	// punctuation along with the link — strip it before parsing.
	const trimmed = input.trim().replace(/[.,;:)\]>]+$/, '');
	if (!trimmed) return null;

	try {
		const url = new URL(trimmed);
		const match = url.pathname.match(/\/(?:users\/log-in|sign-in)\/([^/]+)\/?$/);
		return match ? decodeURIComponent(match[1]) : null;
	} catch {
		// Not a URL — treat as a bare token if it looks like one.
	}

	return /^[A-Za-z0-9_-]+$/.test(trimmed) ? trimmed : null;
}
