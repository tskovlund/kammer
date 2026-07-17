import type { Instance } from './types.js';

/** The one Instance factory for specs — stop the per-file copies. */
export function testInstance(id: string, name: string): Instance {
	return {
		id,
		baseUrl: `https://${id}.example`,
		instanceName: name,
		deviceToken: 't',
		user: { id: `${id}-user`, email: 'a@example.com', displayName: 'A' },
		addedAt: '2026-01-01T00:00:00Z'
	};
}

/**
 * Mock module body for `$lib/instances/instances.svelte.js`. Component
 * specs hand this a `vi.hoisted` holder so tests can swap the list:
 *
 *   const mocks = vi.hoisted(() => ({ list: [] as Instance[] }));
 *   vi.mock('$lib/instances/instances.svelte.js', async () => {
 *     const { instancesMock } = await import('$lib/instances/test-support.js');
 *     return instancesMock(mocks);
 *   });
 *
 * `solo`/`several` derive from the same list here — ONE place, so the
 * mock's semantics can't silently drift from the real store's (which
 * instances.spec.ts pins against the same definitions).
 */
export function instancesMock(holder: { list: Instance[] }) {
	return {
		instances: {
			get list() {
				return holder.list;
			},
			get solo() {
				return holder.list.length === 1;
			},
			get several() {
				return holder.list.length > 1;
			},
			refresh() {}
		}
	};
}

// vitest's `node` test project has no real `localStorage` (that's a
// browser API — see issue #146's browser-project gap), so tests that
// exercise `instanceStore`'s persistence stub this in.
export function fakeLocalStorage() {
	const data = new Map<string, string>();
	return {
		getItem: (key: string) => data.get(key) ?? null,
		setItem: (key: string, value: string) => void data.set(key, value),
		removeItem: (key: string) => void data.delete(key),
		clear: () => data.clear()
	};
}
