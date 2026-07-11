import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/svelte';

import Page from './+page.svelte';

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => vi.unstubAllGlobals());

describe('anonymous instance landing', () => {
	it('renders the ethos, a sign-in link, and the community directory linking into /c/[slug]', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			new Response(
				JSON.stringify({
					data: [{ id: 'c1', name: 'Our Club', slug: 'our-club', description: 'A club.' }]
				}),
				{ status: 200, headers: { 'content-type': 'application/json' } }
			)
		);
		render(Page);

		await waitFor(() => expect(screen.getByText('Our Club')).toBeTruthy());
		expect(screen.getByText(/No ads, no algorithm/)).toBeTruthy();
		expect(screen.getByText('Communities on this instance')).toBeTruthy();
		// `resolve()` may prefix a base path — pin the route, not the prefix.
		expect(screen.getByText('Our Club').closest('a')?.getAttribute('href')).toMatch(
			/\/c\/our-club$/
		);
		expect(document.querySelector('#welcome-sign-in')?.getAttribute('href')).toMatch(/\/sign-in$/);
	});

	// Mirrors the LiveView: the directory section exists only when there is
	// something to list — a failed fetch degrades to ethos + sign-in, never
	// an error message (public surfaces don't render server errors, #253).
	it('hides the directory on fetch failure, keeping ethos and sign-in', async () => {
		vi.mocked(fetch).mockRejectedValueOnce(new TypeError('Failed to fetch'));
		render(Page);

		await waitFor(() => expect(document.querySelector('[aria-busy]')).toBeNull());
		expect(screen.getByText(/No ads, no algorithm/)).toBeTruthy();
		expect(document.querySelector('#welcome-sign-in')).toBeTruthy();
		expect(screen.queryByText('Communities on this instance')).toBeNull();
	});

	// The other way the directory is absent: a successful fetch that lists
	// nothing. Distinct path from the failure above (resolved-empty, not
	// thrown), and the one the page comment's "an empty directory just
	// leaves the ethos and the sign-in button" claim rests on.
	it('hides the directory when the instance lists no communities', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			new Response(JSON.stringify({ data: [] }), {
				status: 200,
				headers: { 'content-type': 'application/json' }
			})
		);
		render(Page);

		await waitFor(() => expect(document.querySelector('[aria-busy]')).toBeNull());
		expect(screen.getByText(/No ads, no algorithm/)).toBeTruthy();
		expect(document.querySelector('#welcome-sign-in')).toBeTruthy();
		expect(screen.queryByText('Communities on this instance')).toBeNull();
	});
});
