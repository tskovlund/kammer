import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';

const mocks = vi.hoisted(() => ({
	instance: {
		id: 'i1',
		baseUrl: 'http://localhost:3000',
		instanceName: 'Example',
		deviceToken: 'token-1',
		user: { id: 'u1', email: 'a@example.com', displayName: 'Alice' },
		addedAt: '2026-01-01T00:00:00Z'
	}
}));
vi.mock('$app/state', () => ({ page: { params: { instance: 'i1' } } }));
vi.mock('$app/paths', () => ({ resolve: (path: string) => path }));
vi.mock('$lib/instances/instances.svelte.js', () => ({
	instances: {
		get list() {
			return [mocks.instance];
		}
	}
}));

import Page from './+page.svelte';

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

// Mount loads devices + passkeys together; both empty is enough to reach the
// ready state where the Passkeys section renders.
async function renderReady() {
	vi.mocked(fetch)
		.mockResolvedValueOnce(jsonResponse({ data: [] }))
		.mockResolvedValueOnce(jsonResponse({ data: [] }));
	render(Page);
	await waitFor(() => expect(screen.getByRole('heading', { name: 'Passkeys' })).toBeTruthy());
}

beforeEach(() => {
	vi.stubGlobal('fetch', vi.fn());
	mocks.instance.baseUrl = 'http://localhost:3000';
});
afterEach(() => {
	vi.unstubAllGlobals();
	document.body.innerHTML = '';
});

describe('devices page — passkey enrollment', () => {
	it("hides the add control and says so when the browser can't register", async () => {
		// jsdom defines no navigator.credentials.create → unsupported.
		await renderReady();
		expect(document.querySelector('#passkey-add')).toBeNull();
		expect(screen.getByText("This browser can't create passkeys.")).toBeTruthy();
	});

	it('hides the add control with the cross-origin note for a different-origin instance', async () => {
		vi.stubGlobal('PublicKeyCredential', class {});
		vi.stubGlobal('navigator', { credentials: { create: vi.fn() } });
		mocks.instance.baseUrl = 'https://kammer.example.com';

		await renderReady();
		expect(document.querySelector('#passkey-add')).toBeNull();
		expect(
			screen.getByText("Passkeys can only be added on this community's own site.")
		).toBeTruthy();
	});

	it('offers the add control for a supported, same-origin instance', async () => {
		vi.stubGlobal('PublicKeyCredential', class {});
		vi.stubGlobal('navigator', { credentials: { create: vi.fn() } });

		await renderReady();
		expect(document.querySelector('#passkey-add')).toBeTruthy();
	});

	it('stays silent — no error — when the user dismisses the browser prompt', async () => {
		vi.stubGlobal('PublicKeyCredential', class {});
		const create = vi
			.fn()
			.mockRejectedValue(Object.assign(new Error('cancelled'), { name: 'NotAllowedError' }));
		vi.stubGlobal('navigator', { credentials: { create } });

		await renderReady();

		// The add begins a challenge, then the OS prompt is dismissed.
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({
				data: {
					challenge: 'chal',
					rp_id: 'localhost',
					challenge_token: 'ctok',
					user_id: 'AQID',
					user_name: 'a@example.com',
					user_display_name: 'Alice',
					exclude_credentials: []
				}
			})
		);
		await fireEvent.click(document.querySelector('#passkey-add')!);

		// A deliberate cancel is not a failure — no neutral error is shown.
		await waitFor(() => expect(create).toHaveBeenCalled());
		expect(document.querySelector('[role="alert"]')).toBeNull();
	});
});
