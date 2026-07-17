import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import { testInstance } from '$lib/instances/test-support.js';
import type { Instance } from '$lib/instances/types.js';

const mocks = vi.hoisted(() => ({ list: [] as Instance[] }));

vi.mock('$app/state', () => ({ page: { params: { instance: 'i1' } } }));
vi.mock('$app/paths', () => ({ resolve: (path: string) => path }));
vi.mock('$lib/instances/instances.svelte.js', async () => {
	const { instancesMock } = await import('$lib/instances/test-support.js');
	return instancesMock(mocks);
});

import Page from './+page.svelte';

// jsdom exposes no PushManager, so the page renders its header over the
// "unsupported" body — exactly enough surface for the description pair.
beforeEach(() => {
	mocks.list = [testInstance('i1', 'Example Club')];
});
afterEach(() => {
	document.body.innerHTML = '';
});

describe('push notifications page — single-account collapse (#322)', () => {
	it('drops the instance name from the description when it is the only account', () => {
		render(Page);

		expect(screen.getByText('Push notifications on this device.')).toBeTruthy();
		expect(screen.queryByText(/Example Club/)).toBeNull();
	});

	it('names the instance when several accounts are added', () => {
		mocks.list = [testInstance('i1', 'Example Club'), testInstance('i2', 'Second Club')];
		render(Page);

		expect(screen.getByText('Push notifications for Example Club.')).toBeTruthy();
	});
});
