import { afterEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import { testInstance } from '$lib/instances/test-support.js';
import type { Instance } from '$lib/instances/types.js';

const mocks = vi.hoisted(() => ({ list: [] as Instance[] }));
vi.mock('$lib/instances/instances.svelte.js', async () => {
	const { instancesMock } = await import('$lib/instances/test-support.js');
	return instancesMock(mocks);
});

import FailedInstancesBanner from './FailedInstancesBanner.svelte';

afterEach(() => {
	document.body.innerHTML = '';
});

describe('failed-instances banner — single-account collapse (#322)', () => {
	it('drops the instance name when it is the only account', () => {
		const only = testInstance('i1', 'North Sea Club');
		mocks.list = [only];
		render(FailedInstancesBanner, {
			props: { failures: [{ instance: only, kind: 'network' as const }] }
		});

		expect(screen.getByText("Couldn't reach your community just now.")).toBeTruthy();
		expect(screen.queryByText(/North Sea Club/)).toBeNull();
	});

	it('names the failing instance when several accounts are added', () => {
		const failing = testInstance('i1', 'North Sea Club');
		mocks.list = [failing, testInstance('i2', 'Other Club')];
		render(FailedInstancesBanner, {
			props: { failures: [{ instance: failing, kind: 'network' as const }] }
		});

		expect(screen.getByText("Couldn't reach North Sea Club just now.")).toBeTruthy();
	});
});
