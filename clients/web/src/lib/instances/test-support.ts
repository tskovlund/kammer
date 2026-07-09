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
