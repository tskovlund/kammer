import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import { testInstance } from '$lib/instances/test-support.js';
import type { Instance } from '$lib/instances/types.js';

const mocks = vi.hoisted(() => ({ list: [] as Instance[] }));

vi.mock('$app/state', () => ({ page: { params: { instance: 'i1' } } }));
vi.mock('$app/navigation', () => ({ goto: vi.fn() }));
vi.mock('$app/paths', () => ({ resolve: (path: string) => path }));
vi.mock('$lib/instances/instances.svelte.js', async () => {
	const { instancesMock } = await import('$lib/instances/test-support.js');
	return instancesMock(mocks);
});
vi.mock('$lib/instances/api.js', () => ({ revokeAndRemoveInstance: vi.fn() }));
vi.mock('$lib/people/api.js', () => ({
	deleteAccount: vi.fn(),
	fetchAccountExportUrl: vi.fn()
}));

import Page from './+page.svelte';

beforeEach(() => {
	mocks.list = [testInstance('i1', 'Example Club')];
});
afterEach(() => {
	document.body.innerHTML = '';
});

describe('data & account — single-account collapse (#322)', () => {
	it('drops the instance name from every description when it is the only account', () => {
		render(Page);

		expect(screen.getByText('Your data and your account.')).toBeTruthy();
		expect(screen.queryByText(/Example Club/)).toBeNull();
	});

	it('names the instance when several accounts are added', () => {
		mocks.list = [testInstance('i1', 'Example Club'), testInstance('i2', 'Second Club')];
		render(Page);

		expect(screen.getByText('Your data and your account on Example Club.')).toBeTruthy();
		expect(screen.getByText(/Download everything Example Club stores about you/)).toBeTruthy();
	});
});
