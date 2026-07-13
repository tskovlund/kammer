import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';

vi.mock('$app/state', () => ({
	page: { params: { instance: 'i1', community: 'our-club', group: 'general' } }
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

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => {
	vi.unstubAllGlobals();
	vi.mocked(goto).mockClear();
	document.body.innerHTML = '';
});

describe('new event page', () => {
	it('lights the location-link field when the server rejects a non-http(s) URL, and stays put', async () => {
		// #247: `location_url` is validated to be http(s) server-side; a bad
		// link 422s keyed on `location_url`, which the form must route to that
		// input rather than the generic "please try again" banner.
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(422, {
				error: {
					code: 'invalid_params',
					message: 'Validation failed.',
					details: { location_url: ['must be a valid http(s) URL'] }
				}
			})
		);
		render(Page);

		await fireEvent.input(document.querySelector('#event-form-title')!, {
			target: { value: 'Rehearsal' }
		});
		await fireEvent.input(document.querySelector('#event-form-starts-at')!, {
			target: { value: '2026-08-01T10:00' }
		});
		await fireEvent.input(document.querySelector('#event-form-location-url')!, {
			target: { value: 'javascript:alert(1)' }
		});
		await fireEvent.submit(document.querySelector('#event-form')!);

		await waitFor(() =>
			expect(screen.getByText('Enter a valid http(s) link (at most 500 characters).')).toBeTruthy()
		);
		// The error lands on the field, so the input is flagged invalid…
		expect(document.querySelector('#event-form-location-url')!.getAttribute('aria-invalid')).toBe(
			'true'
		);
		// …and a rejected create never navigates to the event.
		expect(goto).not.toHaveBeenCalled();
	});
});
