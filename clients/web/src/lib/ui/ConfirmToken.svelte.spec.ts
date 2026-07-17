import { afterEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/svelte';
import ConfirmTokenHarness from './testing/ConfirmTokenHarness.test.svelte';
import ConfirmTokenErrorOverrideHarness from './testing/ConfirmTokenErrorOverrideHarness.test.svelte';

afterEach(() => {
	document.body.innerHTML = '';
});

// The shared landing screen behind every guest/newsletter confirm page
// (issue #185): one token, one POST on mount, one of three outcomes. Every
// `+page.svelte` that uses it is a thin wrapper around this component, so
// its behaviour is exercised here rather than per-route.
describe('ConfirmToken', () => {
	it('shows the success snippet with the confirmation once the token resolves', async () => {
		const confirm = vi.fn().mockResolvedValue({ guest_name: 'Alice', redirect_path: '/x' });
		render(ConfirmTokenHarness, { props: { token: 'tok-1', confirm } });

		await waitFor(() => expect(screen.getByText('Hi Alice')).toBeTruthy());
		expect(confirm).toHaveBeenCalledWith(window.location.origin, 'tok-1');

		// The server's redirect_path becomes a visible way onward (#345) —
		// the field existed unread before this link.
		const link = screen.getByText('Go to the page');
		expect(link.getAttribute('href')).toBe('/x');
	});

	it('shows the neutral error state when the token is rejected', async () => {
		const confirm = vi.fn().mockRejectedValue(new Error('nope'));
		render(ConfirmTokenHarness, { props: { token: 'stale', confirm } });

		await waitFor(() => {
			expect(screen.getByText("That link didn't work")).toBeTruthy();
			expect(screen.getByText('This link is no longer valid.')).toBeTruthy();
		});
	});

	it('shows the neutral error state without calling confirm when no token is in the route', async () => {
		const confirm = vi.fn();
		render(ConfirmTokenHarness, { props: { token: undefined, confirm } });

		await waitFor(() => expect(screen.getByText("That link didn't work")).toBeTruthy());
		expect(confirm).not.toHaveBeenCalled();
	});

	it('lets a caller override the default error state with the caught error', async () => {
		const confirm = vi.fn().mockRejectedValue(new Error('slot_full'));
		render(ConfirmTokenErrorOverrideHarness, { props: { token: 'tok-1', confirm } });

		await waitFor(() => expect(screen.getByText('custom: slot_full')).toBeTruthy());
		expect(screen.queryByText("That link didn't work")).toBeNull();
	});
});
