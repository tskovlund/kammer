/**
 * Last-fetched-data offline reading (issue #186; full offline write queue
 * stays #137). A small `localStorage` snapshot per view — the leanest
 * option that satisfies "last data readable offline with a stale
 * indicator": no offline database, no generic HTTP response cache in the
 * service worker (that would also have to reason about auth headers,
 * multi-instance CORS requests, and cache invalidation on writes — a much
 * bigger surface for the same outcome). Each store that wants offline
 * reading calls `saveSnapshot` after a successful load and `loadSnapshot`
 * as a fallback when a load can't reach any instance.
 */

const STORAGE_PREFIX = 'kammer:snapshot:';
const CURRENT_VERSION = 1;

export interface Snapshot<T> {
	data: T;
	savedAt: string;
}

interface Envelope<T> {
	version: typeof CURRENT_VERSION;
	savedAt: string;
	data: T;
}

function hasLocalStorage(): boolean {
	return typeof localStorage !== 'undefined';
}

/** Persists `data` as the latest snapshot for `key`, stamped with now. */
export function saveSnapshot<T>(key: string, data: T): void {
	if (!hasLocalStorage()) return;
	const envelope: Envelope<T> = {
		version: CURRENT_VERSION,
		savedAt: new Date().toISOString(),
		data
	};
	try {
		localStorage.setItem(STORAGE_PREFIX + key, JSON.stringify(envelope));
	} catch {
		// Storage full or unavailable (private browsing) — offline reading
		// is a nicety, not worth failing the caller's own load over.
	}
}

/**
 * Drops every stored snapshot. Called when an account is removed
 * (sign-out): the merged home/events snapshots mix data across
 * instances, so on a shared device the next signer-in must never be
 * shown the previous user's cached content as an offline fallback.
 */
export function clearSnapshots(): void {
	if (!hasLocalStorage()) return;
	try {
		const stale = Object.keys(localStorage).filter((key) => key.startsWith(STORAGE_PREFIX));
		for (const key of stale) localStorage.removeItem(key);
	} catch {
		// Same stance as saveSnapshot: never fail the caller over storage.
	}
}

/** The last snapshot saved for `key`, or `null` if there isn't one (or it's unreadable). */
export function loadSnapshot<T>(key: string): Snapshot<T> | null {
	if (!hasLocalStorage()) return null;
	const raw = localStorage.getItem(STORAGE_PREFIX + key);
	if (!raw) return null;
	try {
		const parsed = JSON.parse(raw) as Partial<Envelope<T>>;
		if (parsed.version !== CURRENT_VERSION || typeof parsed.savedAt !== 'string') return null;
		return { data: parsed.data as T, savedAt: parsed.savedAt };
	} catch {
		return null;
	}
}
