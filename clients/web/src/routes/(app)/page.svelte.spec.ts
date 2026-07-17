import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import { testInstance } from '$lib/instances/test-support.js';
import type { Instance } from '$lib/instances/types.js';

const mocks = vi.hoisted(() => {
	const bucket = (id: string, communityName: string, instanceName: string) => ({
		key: {
			id,
			instanceId: 'i1',
			communityId: id,
			communityName,
			communitySlug: id,
			instanceName
		},
		posts: [],
		events: []
	});
	return {
		list: [] as Instance[],
		// Two buckets, so the several-buckets condition holds in both tests and
		// only the account cardinality varies.
		buckets: [
			bucket('c1', 'Community A', 'Instance One'),
			bucket('c2', 'Community B', 'Instance One')
		]
	};
});

vi.mock('$lib/instances/instances.svelte.js', async () => {
	const { instancesMock } = await import('$lib/instances/test-support.js');
	return instancesMock(mocks);
});
vi.mock('$lib/home/home-store.svelte.js', () => ({
	createHomeStore: () => ({
		get buckets() {
			return mocks.buckets;
		},
		get allBuckets() {
			return mocks.buckets;
		},
		failedInstances: [],
		loadState: 'ready',
		activeFilter: null,
		isEmpty: false,
		snapshotSavedAt: null,
		setFilter: vi.fn(),
		load: vi.fn(),
		stop: vi.fn()
	})
}));
vi.mock('$lib/realtime/registry.svelte.js', () => ({ reconnectInstance: vi.fn() }));

import Page from './+page.svelte';

beforeEach(() => {
	mocks.list = [testInstance('i1', 'Instance One')];
});
afterEach(() => {
	document.body.innerHTML = '';
});

describe('home — instance provenance collapse (#322)', () => {
	it('shows community headings without an instance subtitle when one account is added', () => {
		render(Page);

		expect(screen.getByRole('heading', { name: 'Community A' })).toBeTruthy();
		expect(screen.getByRole('heading', { name: 'Community B' })).toBeTruthy();
		expect(screen.queryByText('Instance One')).toBeNull();
	});

	it('keeps the instance subtitle when several accounts are added', () => {
		mocks.list = [testInstance('i1', 'Instance One'), testInstance('i2', 'Instance Two')];
		render(Page);

		expect(screen.getAllByText('Instance One').length).toBe(2);
	});
});
