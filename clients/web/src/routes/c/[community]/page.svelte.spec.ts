import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/svelte';

vi.mock('$app/state', () => ({
	page: { params: { community: 'our-club' } }
}));

import Page from './+page.svelte';

function communityResponse() {
	return new Response(
		JSON.stringify({
			data: {
				community: { id: 'c1', name: 'Our Club', description: 'A neighbourhood club.' },
				groups: [{ id: 'g1', name: 'General', slug: 'general' }]
			}
		}),
		{ status: 200, headers: { 'content-type': 'application/json' } }
	);
}

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => vi.unstubAllGlobals());

describe('public community page', () => {
	it("renders the community's name, description, and public groups", async () => {
		vi.mocked(fetch).mockResolvedValueOnce(communityResponse());
		render(Page);

		await waitFor(() => expect(screen.getByText('Our Club')).toBeTruthy());
		expect(screen.getByText('A neighbourhood club.')).toBeTruthy();
		expect(screen.getByText('General')).toBeTruthy();
	});

	it('shows the neutral error state for a nonexistent or non-public community', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			new Response(JSON.stringify({ error: { code: 'not_found', message: 'Not found.' } }), {
				status: 404,
				headers: { 'content-type': 'application/json' }
			})
		);
		render(Page);
		await waitFor(() => expect(screen.getByText('Community not found')).toBeTruthy());
	});
});
