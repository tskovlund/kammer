import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';

vi.mock('$app/state', () => ({
	page: { params: { instance: 'i1', community: 'our-club' } }
}));
vi.mock('$app/navigation', () => ({ goto: vi.fn().mockResolvedValue(undefined) }));
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
		],
		refresh: vi.fn()
	}
}));

import Page from './+page.svelte';
import { goto } from '$app/navigation';

function jsonResponse(status: number, body: unknown) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

// fetchCommunity resolves against the communities *list* and picks by slug.
function communityResponse(viewerCan: string[] = ['create_group']) {
	return jsonResponse(200, {
		data: [{ id: 'c1', name: 'Our Club', slug: 'our-club', viewer_can: viewerCan }]
	});
}

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => {
	vi.unstubAllGlobals();
	vi.mocked(goto).mockClear();
	document.body.innerHTML = '';
});

describe('new group page', () => {
	it('a suggestion pre-fills the form and its shape reaches createGroup on submit', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(communityResponse())
			.mockResolvedValueOnce(
				jsonResponse(201, { data: { id: 'g1', name: 'Public page', slug: 'public-page' } })
			);
		render(Page);

		await waitFor(() => expect(document.querySelector('#group-name')).toBeTruthy());

		// The "Public page" suggestion fills the name (none typed yet) and the
		// visibility/policy shape — a starting point, still editable.
		await fireEvent.click(document.querySelector('#group-suggestion-publicPage')!);
		expect((document.querySelector('#group-name') as HTMLInputElement).value).toBe('Public page');

		await fireEvent.click(document.querySelector('#group-create-submit')!);

		await waitFor(() => expect(goto).toHaveBeenCalled());
		const post = vi.mocked(fetch).mock.calls[1]?.[0] as Request;
		expect(post.method).toBe('POST');
		expect(post.url).toContain('/communities/our-club/groups');
		// Pin the auto-derived slug and the create-only `sealed` default too,
		// not just the suggestion's policy shape.
		expect(await post.json()).toMatchObject({
			name: 'Public page',
			slug: 'public-page',
			visibility: 'public_listed',
			posting_policy: 'admins_only',
			sealed: false
		});
	});

	it('switches names between suggestions but keeps a hand-typed one, and sends the sealed flag', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(communityResponse())
			.mockResolvedValueOnce(
				jsonResponse(201, { data: { id: 'g1', name: 'My Choir', slug: 'my-choir' } })
			);
		render(Page);
		await waitFor(() => expect(document.querySelector('#group-name')).toBeTruthy());
		const nameInput = () => document.querySelector('#group-name') as HTMLInputElement;

		// Untouched name: switching suggestions renames.
		await fireEvent.click(document.querySelector('#group-suggestion-everyone')!);
		expect(nameInput().value).toBe('Everyone');
		await fireEvent.click(document.querySelector('#group-suggestion-publicPage')!);
		expect(nameInput().value).toBe('Public page');

		// Hand-typed name is protected — a later suggestion must not overwrite it.
		await fireEvent.input(nameInput(), { target: { value: 'My Choir' } });
		await fireEvent.click(document.querySelector('#group-suggestion-everyone')!);
		expect(nameInput().value).toBe('My Choir');

		// The create-only sealed checkbox rides through to the request body.
		await fireEvent.click(document.querySelector('#group-sealed')!);
		await fireEvent.click(document.querySelector('#group-create-submit')!);

		await waitFor(() => expect(goto).toHaveBeenCalled());
		const post = vi.mocked(fetch).mock.calls[1]?.[0] as Request;
		expect(await post.json()).toMatchObject({ name: 'My Choir', sealed: true });
	});

	it('renders the slug field error and stays put when the server rejects a taken slug', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(communityResponse())
			// A duplicate slug: the server keys the uniqueness error on `slug`
			// (unique_constraint error_key), which the form must route to the
			// slug field — not the generic "please try again".
			.mockResolvedValueOnce(
				jsonResponse(422, {
					error: {
						code: 'validation',
						message: 'Slug has already been taken.',
						details: { slug: ['has already been taken'] }
					}
				})
			);
		render(Page);
		await waitFor(() => expect(document.querySelector('#group-name')).toBeTruthy());

		await fireEvent.input(document.querySelector('#group-name')!, {
			target: { value: 'Everyone' }
		});
		await fireEvent.click(document.querySelector('#group-create-submit')!);

		await waitFor(() =>
			expect(screen.getByText('That web address is taken or invalid.')).toBeTruthy()
		);
		// A rejected create must not navigate away from the form.
		expect(goto).not.toHaveBeenCalled();
	});

	it('surfaces the shared error banner when a create fails without a mappable field', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(communityResponse())
			// A 422 whose details name no field the form maps (here, empty)
			// falls through to the shared ErrorBanner — the validation kind's
			// localized copy — rather than a per-field message, and the form
			// stays put.
			.mockResolvedValueOnce(
				jsonResponse(422, {
					error: { code: 'validation', message: 'Validation failed.', details: {} }
				})
			);
		render(Page);
		await waitFor(() => expect(document.querySelector('#group-name')).toBeTruthy());

		await fireEvent.input(document.querySelector('#group-name')!, {
			target: { value: 'Everyone' }
		});
		await fireEvent.click(document.querySelector('#group-create-submit')!);

		await waitFor(() =>
			expect(screen.getByText('Please check your input and try again.')).toBeTruthy()
		);
		expect(goto).not.toHaveBeenCalled();
	});

	it('shows a forbidden state, not the form, when the viewer cannot create a group', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(communityResponse([]));
		render(Page);

		await waitFor(() => expect(screen.getByText('Not allowed')).toBeTruthy());
		expect(document.querySelector('#group-name')).toBeNull();
	});
});
