import type { Instance } from './types.js';

const STORAGE_KEY = 'kammer:instances';

function hasLocalStorage(): boolean {
	return typeof localStorage !== 'undefined';
}

function read(): Instance[] {
	if (!hasLocalStorage()) return [];
	const raw = localStorage.getItem(STORAGE_KEY);
	if (!raw) return [];
	try {
		const parsed = JSON.parse(raw);
		return Array.isArray(parsed) ? parsed : [];
	} catch {
		return [];
	}
}

function write(instances: Instance[]): void {
	if (!hasLocalStorage()) return;
	localStorage.setItem(STORAGE_KEY, JSON.stringify(instances));
}

/**
 * Plain (non-reactive) persistence for the added-instance list. Kept
 * framework-light so it's testable under vitest's node environment
 * without a component-test harness (see issue #146) — a Svelte layer
 * wraps this with reactivity once the add-instance screen lands.
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
