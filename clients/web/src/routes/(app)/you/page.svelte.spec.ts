import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import { testInstance } from '$lib/instances/test-support.js';
import type { Instance } from '$lib/instances/types.js';

const mocks = vi.hoisted(() => ({ list: [] as Instance[] }));

vi.mock('$app/paths', () => ({ resolve: (path: string) => path }));
vi.mock('$lib/instances/instances.svelte.js', async () => {
	const { instancesMock } = await import('$lib/instances/test-support.js');
	return instancesMock(mocks);
});
vi.mock('$lib/instances/api.js', () => ({
	fetchInstanceStatus: vi.fn(async () => ({})),
	revokeAndRemoveInstance: vi.fn()
}));

import Page from './+page.svelte';

beforeEach(() => {
	mocks.list = [testInstance('i1', 'Example Club')];
});
afterEach(() => {
	document.body.innerHTML = '';
});

describe('you — single-account collapse (#322)', () => {
	it('presents one plain account: no instance name, no several-servers copy', () => {
		render(Page);

		expect(screen.getByText('Your account')).toBeTruthy();
		expect(screen.queryByText('Your communities')).toBeNull();
		expect(screen.queryByText(/Each one stays on its own server/)).toBeNull();
		expect(screen.queryByText('Example Club')).toBeNull();
		// Without a name to disambiguate, the button's visible text is its name.
		expect(screen.getByRole('button', { name: 'Sign out' })).toBeTruthy();
	});

	it('keeps the named per-community cards when several accounts are added', () => {
		mocks.list = [testInstance('i1', 'Example Club'), testInstance('i2', 'Second Club')];
		render(Page);

		expect(screen.getByText('Your communities')).toBeTruthy();
		expect(screen.getByText('Example Club')).toBeTruthy();
		expect(screen.getByText('Second Club')).toBeTruthy();
		expect(screen.getByRole('button', { name: 'Sign out of Example Club' })).toBeTruthy();
	});
});
