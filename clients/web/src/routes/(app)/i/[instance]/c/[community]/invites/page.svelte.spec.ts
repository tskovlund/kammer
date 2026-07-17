import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';

vi.mock('$app/state', () => ({
	page: { params: { instance: 'i1', community: 'our-club' } }
}));
vi.mock('$lib/instances/instances.svelte.js', async () => {
	const { instancesMock, testInstance } = await import('$lib/instances/test-support.js');
	return instancesMock({ list: [testInstance('i1', 'Example')] });
});

import Page from './+page.svelte';

function jsonResponse(status: number, body: unknown) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => {
	vi.unstubAllGlobals();
	document.body.innerHTML = '';
});

describe('community invites page', () => {
	// The representative render spec for the invite form family (#305):
	// the 422 details land on the email input, not the banner — and any
	// other action clears the lit field error (the group-settings rule).
	it('lights the email field on a 422, suppresses the banner, and clears it on the next action', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(
				jsonResponse(200, {
					data: [{ id: 'c1', name: 'Our Club', slug: 'our-club', viewer_can: ['manage_members'] }]
				})
			)
			.mockResolvedValueOnce(jsonResponse(200, { data: [] }))
			.mockResolvedValueOnce(
				jsonResponse(422, {
					error: {
						code: 'invalid_params',
						message: 'Validation failed.',
						details: { invited_email: ['must have the @ sign and no spaces'] }
					}
				})
			)
			.mockResolvedValueOnce(jsonResponse(201, { data: { id: 'inv1', token: 'tok-1' } }))
			.mockResolvedValueOnce(jsonResponse(200, { data: [] }));
		render(Page);
		await waitFor(() => expect(document.querySelector('#invite-email')).toBeTruthy());

		const input = document.querySelector('#invite-email') as HTMLInputElement;
		await fireEvent.input(input, { target: { value: 'jhon@' } });
		await fireEvent.submit(input.closest('form')!);

		await waitFor(() => expect(screen.getByText('Enter a valid email address.')).toBeTruthy());
		expect(input.getAttribute('aria-invalid')).toBe('true');
		// The field owns the failure — the generic banner stays away.
		expect(screen.queryByText('Please check your input and try again.')).toBeNull();

		await fireEvent.click(document.querySelector('#new-invite-link')!);
		await waitFor(() => expect(screen.queryByText('Enter a valid email address.')).toBeNull());
	});
});
