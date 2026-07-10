import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';

import Page from './+page.svelte';

function jsonResponse(body: unknown, status = 200) {
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

describe('setup wizard', () => {
	it('shows the already-set-up terminal state and never renders the form when setup has completed', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ setup_completed: true }));
		render(Page);

		await waitFor(() => expect(screen.getByText('This instance is already set up')).toBeTruthy());
		expect(document.querySelector('#setup-operator-form')).toBeNull();
	});

	// There is deliberately no separate token-verification step (issue
	// #230) — a boolean oracle over the setup credential — so the token
	// field lives on the operator step alongside the rest of the operator
	// fields, and the wizard advances on it without any API round trip.
	it('renders the setup token field on the operator step, with no separate token step', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ setup_completed: false }));
		render(Page);

		await waitFor(() => expect(document.querySelector('#setup-operator-form')).toBeTruthy());
		expect(screen.getByLabelText('Setup token')).toBeTruthy();
		expect(document.querySelector('#setup-token-form')).toBeNull();
		// Only the status check has happened so far — verifying the token
		// is not a separate network round trip.
		expect(fetch).toHaveBeenCalledTimes(1);
	});

	it('advances from the operator step to the community step on submit', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ setup_completed: false }));
		render(Page);

		await waitFor(() => expect(document.querySelector('#setup-operator-form')).toBeTruthy());
		await fireEvent.input(screen.getByLabelText('Setup token'), {
			target: { value: 'setup-tok' }
		});
		await fireEvent.input(screen.getByLabelText('Your email (instance operator)'), {
			target: { value: 'op@example.com' }
		});
		await fireEvent.input(screen.getByLabelText('Your display name'), {
			target: { value: 'Op' }
		});
		await fireEvent.click(document.querySelector('#setup-operator-submit')!);

		await waitFor(() => expect(document.querySelector('#setup-community-form')).toBeTruthy());
	});

	// The token is only actually checked on the real completion call
	// (`POST /setup`), which answers a neutral 403 for a bad or expired
	// one — the wizard must surface that at the community form, the only
	// form left that can discover it.
	it('surfaces a neutral invalid-token error at the community form on a 403 from POST /setup', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(jsonResponse({ setup_completed: false }))
			.mockResolvedValueOnce(
				jsonResponse({ error: { code: 'forbidden', message: 'Setup is not available.' } }, 403)
			);
		render(Page);

		await waitFor(() => expect(document.querySelector('#setup-operator-form')).toBeTruthy());
		await fireEvent.input(screen.getByLabelText('Setup token'), {
			target: { value: 'wrong-token' }
		});
		await fireEvent.input(screen.getByLabelText('Your email (instance operator)'), {
			target: { value: 'op@example.com' }
		});
		await fireEvent.input(screen.getByLabelText('Your display name'), {
			target: { value: 'Op' }
		});
		await fireEvent.click(document.querySelector('#setup-operator-submit')!);
		await waitFor(() => expect(document.querySelector('#setup-community-form')).toBeTruthy());

		await fireEvent.input(screen.getByLabelText("Your first community's name"), {
			target: { value: 'Our Club' }
		});
		await fireEvent.input(screen.getByLabelText('Community URL slug'), {
			target: { value: 'our-club' }
		});
		await fireEvent.input(screen.getByLabelText("Your first group's name"), {
			target: { value: 'General' }
		});
		await fireEvent.input(screen.getByLabelText('Group URL slug'), {
			target: { value: 'general' }
		});
		await fireEvent.click(document.querySelector('#setup-community-submit')!);

		await waitFor(() => expect(screen.getByText(/invalid or has expired/)).toBeTruthy());
		// Must not advance to the done step on a rejected token.
		expect(document.querySelector('#setup-community-form')).toBeTruthy();
	});
});
