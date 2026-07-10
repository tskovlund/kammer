import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';

vi.mock('$app/state', () => ({
	page: { params: { community: 'our-club', event: 'e1' } }
}));

import Page from './+page.svelte';

function eventResponse() {
	return new Response(
		JSON.stringify({
			data: {
				id: 'e1',
				title: 'Autumn Fair',
				group: { id: 'g1', name: 'General', slug: 'general' },
				starts_at: '2026-09-01T10:00:00Z',
				all_day: false,
				cancelled: false,
				rsvp_counts: { yes: 2, maybe: 1, no: 0 },
				slots: [{ id: 's1', title: 'Bring cake', capacity: 2, taken: 0 }],
				comments: []
			}
		}),
		{ status: 200, headers: { 'content-type': 'application/json' } }
	);
}

function groupResponse(guestRsvpAllowed: boolean) {
	return new Response(
		JSON.stringify({
			data: { name: 'General', slug: 'general', guest_rsvp_allowed: guestRsvpAllowed }
		}),
		{ status: 200, headers: { 'content-type': 'application/json' } }
	);
}

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => vi.unstubAllGlobals());

describe('public event page', () => {
	it('renders the event and hides the RSVP form when the group has guest RSVP turned off', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(eventResponse())
			.mockResolvedValueOnce(groupResponse(false));
		render(Page);

		await waitFor(() => expect(screen.getByText('Autumn Fair')).toBeTruthy());
		expect(document.querySelector('#public-event-rsvp-reveal')).toBeNull();
		expect(document.querySelector('#public-event-slot-claim-reveal-s1')).toBeNull();
	});

	it('POSTs the guest RSVP and shows the neutral confirmation on success', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(eventResponse())
			.mockResolvedValueOnce(groupResponse(true))
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ status: 'confirmation_sent' }), {
					status: 202,
					headers: { 'content-type': 'application/json' }
				})
			);
		render(Page);
		await waitFor(() => expect(screen.getByText('Autumn Fair')).toBeTruthy());

		await fireEvent.click(document.querySelector('#public-event-rsvp-reveal')!);
		await fireEvent.click(document.querySelector('#public-event-rsvp-status-maybe')!);
		await fireEvent.input(document.querySelector('#public-event-rsvp-name')!, {
			target: { value: 'Bob' }
		});
		await fireEvent.input(document.querySelector('#public-event-rsvp-email')!, {
			target: { value: 'bob@example.com' }
		});
		await fireEvent.click(document.querySelector('#public-event-rsvp-submit')!);

		await waitFor(() => expect(screen.getByText('RSVP sent')).toBeTruthy());
		const [request] = vi.mocked(fetch).mock.calls[2];
		const req = request as Request;
		expect(new URL(req.url).pathname).toBe('/api/v1/communities/our-club/events/e1/guest-rsvp');
		expect(await req.clone().json()).toEqual({
			email: 'bob@example.com',
			display_name: 'Bob',
			status: 'maybe'
		});
	});

	it('reveals a per-slot claim form and POSTs the signup for that slot', async () => {
		vi.mocked(fetch)
			.mockResolvedValueOnce(eventResponse())
			.mockResolvedValueOnce(groupResponse(true))
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ status: 'confirmation_sent' }), {
					status: 202,
					headers: { 'content-type': 'application/json' }
				})
			);
		render(Page);
		await waitFor(() => expect(screen.getByText('Bring cake')).toBeTruthy());

		await fireEvent.click(document.querySelector('#public-event-slot-claim-reveal-s1')!);
		await fireEvent.input(document.querySelector('#public-event-slot-claim-s1-name')!, {
			target: { value: 'Carol' }
		});
		await fireEvent.input(document.querySelector('#public-event-slot-claim-s1-email')!, {
			target: { value: 'carol@example.com' }
		});
		await fireEvent.click(document.querySelector('#public-event-slot-claim-s1-submit')!);

		await waitFor(() => expect(screen.getByText('Signup sent')).toBeTruthy());
		const [request] = vi.mocked(fetch).mock.calls[2];
		const req = request as Request;
		expect(new URL(req.url).pathname).toBe(
			'/api/v1/communities/our-club/events/e1/slots/s1/guest-claim'
		);
	});
});
