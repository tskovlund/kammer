import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';

vi.mock('$app/state', () => ({
	page: { params: { community: 'our-club', group: 'general', post: 'p1' } }
}));

import Page from './+page.svelte';

function groupResponse(guestCommentAllowed: boolean) {
	return new Response(
		JSON.stringify({
			data: { name: 'General', slug: 'general', guest_comment_allowed: guestCommentAllowed }
		}),
		{ status: 200, headers: { 'content-type': 'application/json' } }
	);
}

function postResponse() {
	return new Response(
		JSON.stringify({
			data: {
				id: 'p1',
				published_at: '2026-06-01T00:00:00Z',
				author: { type: 'user', id: 'u1', display_name: 'Alice' },
				body_markdown: 'Hello, group!',
				attachments: [],
				comments: []
			}
		}),
		{ status: 200, headers: { 'content-type': 'application/json' } }
	);
}

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => vi.unstubAllGlobals());

describe('public post page', () => {
	it('renders the post body and hides the comment form when the group has it turned off', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(groupResponse(false))
			.mockResolvedValueOnce(postResponse());
		render(Page);

		await waitFor(() => expect(screen.getByText('Hello, group!')).toBeTruthy());
		expect(document.querySelector('#public-post-comment-form')).toBeNull();
	});

	it('POSTs the guest comment and shows the neutral confirmation on success', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(groupResponse(true))
			.mockResolvedValueOnce(postResponse())
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ status: 'confirmation_sent' }), {
					status: 202,
					headers: { 'content-type': 'application/json' }
				})
			);
		render(Page);
		await waitFor(() => expect(screen.getByText('Hello, group!')).toBeTruthy());

		await fireEvent.input(document.querySelector('#public-post-comment-body')!, {
			target: { value: 'Nice post!' }
		});
		await fireEvent.input(document.querySelector('#public-post-comment-name')!, {
			target: { value: 'Bob' }
		});
		await fireEvent.input(document.querySelector('#public-post-comment-email')!, {
			target: { value: 'bob@example.com' }
		});
		await fireEvent.click(document.querySelector('#public-post-comment-submit')!);

		await waitFor(() => expect(screen.getByText('Comment sent')).toBeTruthy());
		const [request] = vi.mocked(fetch).mock.calls[2];
		const req = request as Request;
		expect(new URL(req.url).pathname).toBe(
			'/api/v1/communities/our-club/groups/general/posts/p1/guest-comment'
		);
		expect(await req.clone().json()).toEqual({
			email: 'bob@example.com',
			display_name: 'Bob',
			body_markdown: 'Nice post!'
		});
	});
});
