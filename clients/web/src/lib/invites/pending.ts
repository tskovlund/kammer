/**
 * The invite token pending through a sign-in round-trip (issue #255):
 * the invite landing page stores it before sending the visitor into
 * registration or sign-in, and the magic-link deep-link route
 * (`/sign-in/[token]`) picks it up after the exchange to accept the
 * invite and land in the joined community.
 *
 * localStorage with a short TTL, not sessionStorage: the common real
 * path opens the magic link from a mail client in a NEW tab, which a
 * per-tab store never sees — the newcomer would end up signed in but
 * silently not joined. The TTL (and read-once `take`) keeps the other
 * edge covered too: a pending invite is a property of this one join
 * attempt and must not survive to ambush an unrelated sign-in days
 * later on a shared device.
 */

const STORAGE_KEY = 'kammer:pending-invite';

/** Generous for an email round-trip, useless to an ambush later. */
const TTL_MS = 30 * 60 * 1000;

// Invite tokens are URL-safe base64; storage is user-editable, so
// anything else read back is dropped rather than sent to the API.
const TOKEN_SHAPE = /^[A-Za-z0-9_-]+$/;

export function rememberPendingInvite(token: string): void {
	if (typeof localStorage === 'undefined' || !TOKEN_SHAPE.test(token)) return;
	try {
		localStorage.setItem(STORAGE_KEY, JSON.stringify({ token, expiresAt: Date.now() + TTL_MS }));
	} catch {
		// Storage full/unavailable: the visitor still signs in; re-opening
		// the invite link offers the signed-in one-tap accept instead.
	}
}

/**
 * Reads and clears the pending token — one join attempt per stored
 * token, whether or not the accept that follows succeeds (a dead
 * invite must not re-fire on every later sign-in). Pass `matching`
 * to consume the entry only when it holds that exact token: the
 * invite page must not blow away a DIFFERENT invite's pending entry
 * just because its own accept is about to run (zero attempts is not
 * "one attempt").
 */
export function takePendingInvite(matching?: string): string | null {
	if (typeof localStorage === 'undefined') return null;
	const raw = localStorage.getItem(STORAGE_KEY);
	if (!raw) return null;
	if (matching !== undefined) {
		try {
			const peek = JSON.parse(raw) as { token?: unknown };
			if (peek.token !== matching) return null;
		} catch {
			// Malformed: fall through and let the shared path clear it.
		}
	}
	localStorage.removeItem(STORAGE_KEY);
	try {
		const parsed = JSON.parse(raw) as { token?: unknown; expiresAt?: unknown };
		if (
			typeof parsed.token !== 'string' ||
			!TOKEN_SHAPE.test(parsed.token) ||
			typeof parsed.expiresAt !== 'number' ||
			parsed.expiresAt < Date.now()
		) {
			return null;
		}
		return parsed.token;
	} catch {
		return null;
	}
}
