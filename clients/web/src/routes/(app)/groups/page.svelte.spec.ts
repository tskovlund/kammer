import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/svelte';
import { testInstance } from '$lib/instances/test-support.js';
import type { Instance } from '$lib/instances/types.js';

const mocks = vi.hoisted(() => ({ list: [] as Instance[] }));

vi.mock('$lib/instances/instances.svelte.js', async () => {
	const { instancesMock } = await import('$lib/instances/test-support.js');
	return instancesMock(mocks);
});

import Page from './+page.svelte';

function jsonResponse(body: unknown) {
	return new Response(JSON.stringify(body), {
		status: 200,
		headers: { 'content-type': 'application/json' }
	});
}

// The page fetches the communities list, then each community's groups.
function stubEmptyCommunity(viewerCan: string[]) {
	vi.mocked(fetch)
		.mockResolvedValueOnce(
			jsonResponse({
				data: [{ id: 'c1', name: 'Our Club', slug: 'our-club', viewer_can: viewerCan }]
			})
		)
		.mockResolvedValueOnce(jsonResponse({ data: [] }));
}

beforeEach(() => {
	vi.stubGlobal('fetch', vi.fn());
	mocks.list = [testInstance('i1', 'Example')];
});
afterEach(() => {
	vi.unstubAllGlobals();
	document.body.innerHTML = '';
});

describe('groups directory — instance provenance collapse (#322)', () => {
	it('shows the community heading without an instance qualifier with a single account', async () => {
		stubEmptyCommunity([]);
		render(Page);

		await waitFor(() => expect(screen.getByText('Our Club')).toBeTruthy());
		expect(screen.queryByText(/· Example/)).toBeNull();
	});

	it('qualifies each community with its instance when several accounts are added', async () => {
		mocks.list = [testInstance('i1', 'Example'), testInstance('i2', 'Other')];
		// Both instances load in parallel, so route by URL instead of queueing.
		vi.mocked(fetch).mockImplementation(async (input) => {
			const url = String(input);
			return url.includes('/groups')
				? jsonResponse({ data: [] })
				: jsonResponse({
						data: [{ id: 'c1', name: 'Our Club', slug: 'our-club', viewer_can: [] }]
					});
		});
		render(Page);

		await waitFor(() => expect(screen.getByText('· Example')).toBeTruthy());
		expect(screen.getByText('· Other')).toBeTruthy();
	});
});

describe('groups directory cold-start', () => {
	it('a community with no groups shows a warm empty state with a create CTA into the new-group route', async () => {
		stubEmptyCommunity(['create_group']);
		render(Page);

		await waitFor(() => expect(screen.getByText('Create your first group')).toBeTruthy());
		expect(screen.getByText('Create your first group').closest('a')?.getAttribute('href')).toMatch(
			/\/i\/i1\/c\/our-club\/g\/new$/
		);
	});

	it('keeps the empty-state copy but hides the create affordance where the viewer cannot create a group', async () => {
		stubEmptyCommunity([]);
		render(Page);

		await waitFor(() => expect(screen.getByText('No groups yet')).toBeTruthy());
		expect(screen.queryByText('Create your first group')).toBeNull();
	});

	it('offers a "New group" link on a non-empty community when the viewer can create', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(
				jsonResponse({
					data: [{ id: 'c1', name: 'Our Club', slug: 'our-club', viewer_can: ['create_group'] }]
				})
			)
			.mockResolvedValueOnce(jsonResponse({ data: [{ id: 'g1', name: 'Brass', slug: 'brass' }] }));
		render(Page);

		await waitFor(() => expect(screen.getByText('Brass')).toBeTruthy());
		expect(screen.getByText('New group').closest('a')?.getAttribute('href')).toMatch(
			/\/i\/i1\/c\/our-club\/g\/new$/
		);
	});
});
