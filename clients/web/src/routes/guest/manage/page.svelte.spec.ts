import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';

import Page from './+page.svelte';

// The management token travels in the URL *fragment* (`…/guest/manage#tok`,
// ADR 0026) rather than a route param — browsers never send the fragment to
// the server, so the page reads it from `window.location.hash` on mount
// instead of `$app/state`'s `page.params` (unlike the confirm pages, which
// still use a `[token]` route param).
function setHash(hash: string): void {
	window.location.hash = hash;
}

function manageStateResponse(overrides: Partial<Record<string, unknown>> = {}) {
	return new Response(
		JSON.stringify({
			data: {
				identity: { display_name: 'Alice', email: 'alice@example.com' },
				rsvps: [{ event_id: 'e1', event_title: 'Picnic', status: 'yes' }],
				claims: [{ claim_id: 'c1', slot_title: 'Bring cake', event_title: 'Autumn Fair' }],
				comments: [],
				subscriptions: [
					{
						subscription_id: 's1',
						community_name: 'Our Club',
						group_name: 'General',
						cadence: 'weekly'
					}
				],
				...overrides
			}
		}),
		{ status: 200, headers: { 'content-type': 'application/json' } }
	);
}

beforeEach(() => {
	vi.stubGlobal('fetch', vi.fn());
	setHash('#tok-1');
});
afterEach(() => {
	vi.unstubAllGlobals();
	document.body.innerHTML = '';
	setHash('');
});

describe('guest manage page', () => {
	it('renders the RSVP, claim, and subscription sections from the fetched inventory', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(manageStateResponse());
		render(Page);

		await waitFor(() => expect(screen.getByText('Picnic')).toBeTruthy());
		expect(screen.getByText('Bring cake')).toBeTruthy();
		expect(screen.getByText('Our Club · General')).toBeTruthy();
		expect(screen.getByText('Alice · alice@example.com')).toBeTruthy();
	});

	// ADR 0026: the token is a Bearer credential, never a path segment — a
	// path segment would leak into access/proxy logs and Referer headers.
	it('fetches the manage state with the fragment token as a Bearer header, not in the URL', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(manageStateResponse());
		render(Page);

		await waitFor(() => expect(screen.getByText('Picnic')).toBeTruthy());
		const [request] = vi.mocked(fetch).mock.calls[0];
		const req = request as Request;
		expect(req.headers.get('authorization')).toBe('Bearer tok-1');
		expect(req.url).not.toContain('tok-1');
		expect(new URL(req.url).pathname).toBe('/api/v1/guest/manage');
	});

	it('shows the neutral error state for an invalid or erased token', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			new Response(JSON.stringify({ error: { code: 'not_found', message: 'Not found.' } }), {
				status: 404,
				headers: { 'content-type': 'application/json' }
			})
		);
		render(Page);
		await waitFor(() => expect(screen.getByText("That link didn't work")).toBeTruthy());
	});

	// An empty fragment (link opened without its hash, or copy/pasted
	// without it) must answer the same neutral state the API's 404 gives a
	// bad token — without ever making a request with an empty credential.
	it('shows the neutral error state without calling the API when the fragment is empty', async () => {
		setHash('');
		render(Page);
		await waitFor(() => expect(screen.getByText("That link didn't work")).toBeTruthy());
		expect(fetch).not.toHaveBeenCalled();
	});

	it('moves focus to the confirm panel, then to the trigger again on cancel', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(manageStateResponse());
		render(Page);
		await waitFor(() => expect(screen.getByText('Picnic')).toBeTruthy());

		const eraseButton = document.querySelector('#guest-manage-erase-button') as HTMLButtonElement;
		eraseButton.focus();
		await fireEvent.click(eraseButton);

		const heading = await screen.findByText('Erase everything?');
		await waitFor(() => expect(document.activeElement).toBe(heading));

		const cancel = document.querySelector('#guest-manage-erase-cancel') as HTMLButtonElement;
		await fireEvent.click(cancel);

		// Svelte destroys and re-creates the button across the `{#if}` branch
		// switch, so the re-focused element is a new node with the same id
		// rather than the one originally captured — assert on identity via
		// id, not node reference.
		await waitFor(() => expect(screen.queryByText('Erase everything?')).toBeNull());
		expect(document.activeElement?.id).toBe('guest-manage-erase-button');
	});

	it('erases the guest and shows the terminal state on confirm', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(manageStateResponse())
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ status: 'erased' }), {
					status: 200,
					headers: { 'content-type': 'application/json' }
				})
			);
		render(Page);
		await waitFor(() => expect(screen.getByText('Picnic')).toBeTruthy());

		await fireEvent.click(document.querySelector('#guest-manage-erase-button')!);
		await screen.findByText('Erase everything?');
		await fireEvent.click(document.querySelector('#guest-manage-erase-confirm')!);

		await waitFor(() => expect(screen.getByText('Your data has been erased')).toBeTruthy());
		const [request] = vi.mocked(fetch).mock.calls[1];
		const req = request as Request;
		expect(req.method).toBe('DELETE');
		expect(req.headers.get('authorization')).toBe('Bearer tok-1');
		expect(req.url).not.toContain('tok-1');
	});
});
