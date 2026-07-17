import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import { testInstance } from '$lib/instances/test-support.js';
import type { Instance } from '$lib/instances/types.js';

const mocks = vi.hoisted(() => ({ list: [] as Instance[] }));

vi.mock('$lib/instances/instances.svelte.js', async () => {
	const { instancesMock } = await import('$lib/instances/test-support.js');
	return instancesMock(mocks);
});
// `store` is dereferenced only when the page calls `createSearchStore()`
// at render time, so it can stay a plain module-level const below.
vi.mock('$lib/tools/search-store.svelte.js', () => ({ createSearchStore: () => store }));

import Page from './+page.svelte';

const primary = testInstance('i1', 'North Sea Club');
const store = {
	loadState: 'ready',
	isEmpty: false,
	query: 'minutes',
	failedInstances: [{ instance: primary, kind: 'server' as const }],
	buckets: [
		{
			id: 'i1:c1',
			community: { name: 'Our Club', slug: 'our-club' },
			instance: primary,
			groupSlugById: {},
			results: { posts: [], comments: [], events: [], files: [] }
		}
	],
	run: vi.fn(),
	stop: vi.fn()
};

beforeEach(() => {
	mocks.list = [primary];
});
afterEach(() => {
	document.body.innerHTML = '';
});

describe('search — instance provenance collapse (#322)', () => {
	// The failure line's solo/multi wording is owned by `failureMessage`
	// (FailedInstancesBanner.svelte.spec.ts); here it only needs to show up.
	it('drops instance names from failure copy and bucket headings with a single account', () => {
		render(Page);

		expect(screen.getByText(/had trouble responding/)).toBeTruthy();
		expect(screen.getByText('Our Club')).toBeTruthy();
		expect(screen.queryByText(/North Sea Club/)).toBeNull();
	});

	it('qualifies bucket headings with the instance when several accounts are added', () => {
		mocks.list = [primary, testInstance('i2', 'Other Club')];
		render(Page);

		expect(screen.getByText(/· North Sea Club/)).toBeTruthy();
	});
});
