import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { ApiError } from '$lib/api/errors.js';
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

import { deleteAccount } from '$lib/people/api.js';
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

describe('data & account — step-up gate (#323)', () => {
	it('opens the step-up dialog, not the error copy, when deletion is gated', async () => {
		// The server's 401 step_up_required is a gate, not a failure: the
		// dialog must open and the delete error copy must NOT render.
		vi.mocked(deleteAccount).mockRejectedValueOnce(
			new ApiError('step_up', 'step up', 401, {}, 'step_up_required')
		);
		render(Page);

		await fireEvent.click(screen.getByRole('button', { name: 'Delete my account' }));
		await fireEvent.input(screen.getByLabelText(/Type your email address/), {
			target: { value: 'a@example.com' }
		});
		await fireEvent.submit(document.querySelector('#account-delete-form')!);

		await waitFor(() => expect(screen.getByRole('dialog')).toBeTruthy());
		expect(document.querySelector('[role="alert"]')).toBeNull();
	});
});
