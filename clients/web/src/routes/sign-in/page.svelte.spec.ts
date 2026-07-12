import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';

import Page from './+page.svelte';

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

// Reach the email step (where the passkey affordance lives) by probing an
// instance. Default to a *same-origin* address — the jsdom test origin is
// http://localhost:3000 — so the origin gate is satisfied and the
// browser-capability axis is what's under test; pass a cross-origin
// address to exercise the other axis.
async function reachEmailStep(address = 'http://localhost:3000') {
	vi.mocked(fetch).mockResolvedValueOnce(
		jsonResponse({ instance_name: 'Example Club', features: { registration: 'closed' } })
	);
	render(Page);
	await fireEvent.input(screen.getByLabelText('Community address'), {
		target: { value: address }
	});
	await fireEvent.click(document.querySelector('#signin-instance-submit')!);
	await waitFor(() => expect(document.querySelector('#signin-email-form')).toBeTruthy());
}

describe('sign-in passkey affordance', () => {
	beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
	afterEach(() => {
		vi.unstubAllGlobals();
		document.body.innerHTML = '';
	});

	it('is hidden where WebAuthn is unavailable, offering no button that can only fail', async () => {
		// jsdom defines neither PublicKeyCredential nor navigator.credentials,
		// so this is the genuine unsupported path (same-origin, so capability
		// is the only reason it's hidden).
		await reachEmailStep();
		expect(document.querySelector('#signin-passkey')).toBeNull();
		// The email path is still fully present — passkeys are additive.
		expect(document.querySelector('#signin-email-submit')).toBeTruthy();
	});

	it('is hidden for a cross-origin instance even when the browser supports passkeys', async () => {
		// A passkey is bound to the serving origin; the assertion for a
		// cross-origin instance can only throw SecurityError, so the button
		// must not appear despite full browser support.
		vi.stubGlobal('PublicKeyCredential', class {});
		vi.stubGlobal('navigator', { credentials: { get: vi.fn() } });

		await reachEmailStep('kammer.example.com');
		expect(document.querySelector('#signin-passkey')).toBeNull();
		expect(document.querySelector('#signin-email-submit')).toBeTruthy();
	});

	it('is offered for a same-origin instance the browser can run an assertion for', async () => {
		vi.stubGlobal('PublicKeyCredential', class {});
		vi.stubGlobal('navigator', { credentials: { get: vi.fn() } });

		await reachEmailStep();
		expect(document.querySelector('#signin-passkey')).toBeTruthy();
	});

	it('renders one neutral error and stays put when the ceremony fails', async () => {
		vi.stubGlobal('PublicKeyCredential', class {});
		// The browser yields no credential — the failure the user actually
		// sees. The neutral no-oracle guarantee is ultimately a *rendered*
		// property, so pin it at the page, not just the API layer.
		vi.stubGlobal('navigator', { credentials: { get: vi.fn().mockResolvedValue(null) } });

		await reachEmailStep();
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ challenge: 'chal', challenge_token: 'ctok', rp_id: 'localhost' })
		);
		await fireEvent.click(document.querySelector('#signin-passkey')!);

		await waitFor(() => expect(screen.getByText(/didn't work/i)).toBeTruthy());
		// Did not navigate away or advance — still on the email step, with the
		// email path intact as the fallback the error points to.
		expect(document.querySelector('#signin-email-form')).toBeTruthy();
	});
});
