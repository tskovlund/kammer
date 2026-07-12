import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';

vi.mock('$app/state', () => ({
	page: { params: { community: 'our-club', group: 'general' } }
}));

import Page from './+page.svelte';

function groupResponse(guestSubscribeAllowed = false) {
	return new Response(
		JSON.stringify({
			data: {
				name: 'General',
				slug: 'general',
				description: 'Everyone.',
				guest_subscribe_allowed: guestSubscribeAllowed
			}
		}),
		{ status: 200, headers: { 'content-type': 'application/json' } }
	);
}

function emptyPostsResponse() {
	return new Response(JSON.stringify({ data: [], next_cursor: null }), {
		status: 200,
		headers: { 'content-type': 'application/json' }
	});
}

function postsResponse(id: string, nextCursor: string | null) {
	return new Response(
		JSON.stringify({
			data: [
				{
					id,
					published_at: '2026-06-01T00:00:00Z',
					author: { type: 'user', id: 'u1', display_name: 'Alice' },
					body_markdown: `Post ${id}`
				}
			],
			next_cursor: nextCursor
		}),
		{ status: 200, headers: { 'content-type': 'application/json' } }
	);
}

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => vi.unstubAllGlobals());

describe('public group page', () => {
	it('renders the feed from the fetched page and paginates via load more', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(groupResponse())
			.mockResolvedValueOnce(postsResponse('p1', 'cursor-2'))
			.mockResolvedValueOnce(postsResponse('p2', null));
		render(Page);

		await waitFor(() => expect(screen.getByText('Post p1')).toBeTruthy());
		expect(screen.queryByText('Post p2')).toBeNull();

		await fireEvent.click(document.querySelector('#public-group-load-more')!);
		await waitFor(() => expect(screen.getByText('Post p2')).toBeTruthy());

		// The second page's null next_cursor means there's nothing left to
		// page through — the button disappears rather than staying present
		// and inert.
		expect(document.querySelector('#public-group-load-more')).toBeNull();
	});

	it('shows the empty state when the group has no posts yet', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(groupResponse())
			.mockResolvedValueOnce(emptyPostsResponse());
		render(Page);
		await waitFor(() => expect(screen.getByText('Nothing posted yet.')).toBeTruthy());
	});

	it('hides the newsletter form when the group has not opted into guest subscriptions', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(groupResponse(false))
			.mockResolvedValueOnce(emptyPostsResponse());
		render(Page);
		// Gate on the group heading, not the empty-state text, so this test
		// asserts one thing the empty-state test doesn't: the form's absence.
		await waitFor(() => expect(screen.getByRole('heading', { name: 'General' })).toBeTruthy());
		expect(document.querySelector('#public-group-subscribe-form')).toBeNull();
	});

	it('POSTs a subscription with the chosen cadence and shows the neutral confirmation', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(groupResponse(true))
			.mockResolvedValueOnce(emptyPostsResponse())
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ status: 'confirmation_sent' }), {
					status: 202,
					headers: { 'content-type': 'application/json' }
				})
			);
		render(Page);
		await waitFor(() =>
			expect(document.querySelector('#public-group-subscribe-form')).toBeTruthy()
		);

		await fireEvent.change(document.querySelector('#public-group-subscribe-cadence')!, {
			target: { value: 'weekly' }
		});
		await fireEvent.input(document.querySelector('#public-group-subscribe-name')!, {
			target: { value: 'Bob' }
		});
		await fireEvent.input(document.querySelector('#public-group-subscribe-email')!, {
			target: { value: 'bob@example.com' }
		});
		await fireEvent.click(document.querySelector('#public-group-subscribe-submit')!);

		await waitFor(() => expect(screen.getByText('Confirm your subscription')).toBeTruthy());
		const [request] = vi.mocked(fetch).mock.calls[2];
		const req = request as Request;
		expect(new URL(req.url).pathname).toBe(
			'/api/v1/communities/our-club/groups/general/newsletter'
		);
		expect(await req.clone().json()).toEqual({
			email: 'bob@example.com',
			display_name: 'Bob',
			cadence: 'weekly'
		});
	});
});
