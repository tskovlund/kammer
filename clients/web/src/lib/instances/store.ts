import type { Instance } from './types.js';

const STORAGE_KEY = 'kammer:instances';
const CURRENT_VERSION = 1;

/**
 * Persisted shape (issue #158): a versioned envelope, so future schema
 * changes can migrate instead of guessing. Version history:
 * - v0 (unversioned): a bare `Instance[]` — still read, migrated on the
 *   next write.
 * - v1: `{ version: 1, instances: Instance[] }`.
 *
 * Cross-tab coherence is deliberately last-write-wins: no `storage`
 * event listener, reads happen per operation. Two tabs mutating
 * concurrently can briefly disagree until the next read; acceptable
 * for a session list that changes a few times a year.
 */
interface Envelope {
	version: typeof CURRENT_VERSION;
	instances: Instance[];
}

function hasLocalStorage(): boolean {
	return typeof localStorage !== 'undefined';
}

/**
 * localStorage is user-editable and survives app versions, so nothing
 * about its contents can be trusted at read time (issue #158): every
 * element is shape-checked and malformed ones are dropped rather than
 * allowed to poison every consumer of the list.
 */
function isValidInstance(value: unknown): value is Instance {
	if (typeof value !== 'object' || value === null) return false;
	const candidate = value as Record<string, unknown>;
	if (typeof candidate.user !== 'object' || candidate.user === null) return false;
	const user = candidate.user as Record<string, unknown>;
	return (
		typeof candidate.id === 'string' &&
		typeof candidate.baseUrl === 'string' &&
		typeof candidate.instanceName === 'string' &&
		typeof candidate.deviceToken === 'string' &&
		typeof candidate.addedAt === 'string' &&
		typeof user.id === 'string' &&
		typeof user.email === 'string' &&
		(user.displayName === null || typeof user.displayName === 'string')
	);
}

function unwrap(parsed: unknown): unknown[] {
	// v0: a bare array, from before the envelope existed.
	if (Array.isArray(parsed)) return parsed;
	if (
		typeof parsed === 'object' &&
		parsed !== null &&
		(parsed as Record<string, unknown>).version === CURRENT_VERSION &&
		Array.isArray((parsed as Record<string, unknown>).instances)
	) {
		return (parsed as { instances: unknown[] }).instances;
	}
	// Unknown future version or garbage — safer to start empty than to
	// misinterpret a shape this version doesn't understand.
	return [];
}

function read(): Instance[] {
	if (!hasLocalStorage()) return [];
	const raw = localStorage.getItem(STORAGE_KEY);
	if (!raw) return [];
	try {
		return unwrap(JSON.parse(raw)).filter(isValidInstance);
	} catch {
		return [];
	}
}

function write(instances: Instance[]): void {
	if (!hasLocalStorage()) return;
	const envelope: Envelope = { version: CURRENT_VERSION, instances };
	localStorage.setItem(STORAGE_KEY, JSON.stringify(envelope));
}

/**
 * Plain (non-reactive) persistence for the added-instance list — the
 * reactive layer lives in instances.svelte.ts. Kept framework-light so
 * it's testable under vitest's node environment without a component-test
 * harness (see issue #146).
 */
export const instanceStore = {
	list(): Instance[] {
		return read();
	},

	get(id: string): Instance | undefined {
		return read().find((instance) => instance.id === id);
	},

	add(instance: Instance): void {
		// Dedupe by (baseUrl, user) rather than `id` — `id` is a fresh
		// crypto.randomUUID() minted on every sign-in (see api.ts), so
		// re-authenticating to an already-added instance must replace the
		// existing entry, not append a duplicate.
		const instances = read().filter(
			(existing) =>
				!(existing.baseUrl === instance.baseUrl && existing.user.id === instance.user.id)
		);
		write([...instances, instance]);
	},

	remove(id: string): void {
		write(read().filter((instance) => instance.id !== id));
	},

	clear(): void {
		write([]);
	}
};
