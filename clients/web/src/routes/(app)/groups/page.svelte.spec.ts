import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/svelte';

vi.mock('$lib/instances/instances.svelte.js', () => ({
	instances: {
		list: [
			{
				id: 'i1',
				baseUrl: 'https://kammer.example.com',
				instanceName: 'Example',
				deviceToken: 'token-1',
				user: { id: 'u1', email: 'a@example.com', displayName: 'Alice' },
				addedAt: '2026-01-01T00:00:00Z'
			}
		]
	}
}));

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

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => {
	vi.unstubAllGlobals();
	document.body.innerHTML = '';
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
