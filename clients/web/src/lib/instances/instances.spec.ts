import { describe, expect, it, vi } from 'vitest';

vi.mock('./store.js', () => ({ instanceStore: { list: vi.fn(() => []) } }));

import { instanceStore } from './store.js';
import { instances } from './instances.svelte.js';
import { testInstance } from './test-support.js';

describe('instances cardinality', () => {
	it('solo is exactly one added, several strictly more (#322 display collapse)', () => {
		// The component specs mock this store via `instancesMock`, which
		// re-derives both getters from its holder list — this walk against
		// the REAL store is what pins those semantics, so both getters get
		// asserted at every cardinality.
		expect(instances.solo).toBe(false); // none added at import time
		expect(instances.several).toBe(false);

		vi.mocked(instanceStore.list).mockReturnValue([testInstance('a', 'a')]);
		instances.refresh();
		expect(instances.solo).toBe(true);
		expect(instances.several).toBe(false);

		vi.mocked(instanceStore.list).mockReturnValue([testInstance('a', 'a'), testInstance('b', 'b')]);
		instances.refresh();
		expect(instances.solo).toBe(false);
		expect(instances.several).toBe(true);
	});
});
