import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	GuestApiError,
	confirmGuestRsvp,
	eraseGuest,
	fetchGuestManageState,
	setGuestRsvp
} from './api';

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => vi.unstubAllGlobals());

describe('confirmGuestRsvp', () => {
	it('returns the confirmed guest name on success', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ data: { guest_name: 'Alice', redirect_path: '/c/x/events/1' } })
		);
		const result = await confirmGuestRsvp('https://kammer.example.com', 'tok');
		expect(result).toEqual({ guest_name: 'Alice', redirect_path: '/c/x/events/1' });
	});

	// The API answers one neutral 404 for invalid, expired, and already-used
	// tokens (never an oracle — KammerWeb.Api.GuestController) — this is the
	// one behaviour every confirm page depends on to show its error state.
	it('surfaces an invalid/expired token as a not_found GuestApiError', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ error: { code: 'not_found', message: 'This link is no longer valid.' } }, 404)
		);
		await expect(confirmGuestRsvp('https://kammer.example.com', 'stale')).rejects.toMatchObject({
			kind: 'not_found',
			status: 404
		});
	});

	it('throws GuestApiError, not a raw TypeError, when the network request fails', async () => {
		vi.mocked(fetch).mockRejectedValueOnce(new TypeError('Failed to fetch'));
		await expect(confirmGuestRsvp('https://unreachable.example.com', 'tok')).rejects.toThrow(
			GuestApiError
		);
	});
});

describe('fetchGuestManageState', () => {
	it('returns the guest inventory', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({
				data: {
					identity: { display_name: 'Alice', email: 'alice@example.com' },
					rsvps: [],
					claims: [],
					comments: [],
					subscriptions: []
				}
			})
		);
		const state = await fetchGuestManageState('https://kammer.example.com', 'tok');
		expect(state.identity.display_name).toBe('Alice');
	});

	// ADR 0026: the long-lived management token travels as a Bearer header,
	// never a URL path segment (a path segment would leak into access/proxy
	// logs and Referer) — this is the one behaviour the manage page and
	// every mutation below depend on.
	it('sends the token as an Authorization Bearer header, never in the URL', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({
				data: {
					identity: { display_name: 'Alice', email: 'alice@example.com' },
					rsvps: [],
					claims: [],
					comments: [],
					subscriptions: []
				}
			})
		);
		await fetchGuestManageState('https://kammer.example.com', 'tok');
		const [request] = vi.mocked(fetch).mock.calls[0];
		const req = request as Request;
		expect(req.headers.get('authorization')).toBe('Bearer tok');
		expect(req.url).toBe('https://kammer.example.com/api/v1/guest/manage');
	});
});

describe('setGuestRsvp and eraseGuest', () => {
	it('PUTs the new status to the token-less path and returns the refreshed inventory', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({
				data: {
					identity: { display_name: 'Alice', email: 'alice@example.com' },
					rsvps: [{ event_id: 'e1', event_title: 'Picnic', status: 'no' }],
					claims: [],
					comments: [],
					subscriptions: []
				}
			})
		);
		const state = await setGuestRsvp('https://kammer.example.com', 'tok', 'e1', 'no');
		expect(state.rsvps[0].status).toBe('no');
		const [request] = vi.mocked(fetch).mock.calls[0];
		const req = request as Request;
		expect(req.method).toBe('PUT');
		expect(req.url).toBe('https://kammer.example.com/api/v1/guest/manage/rsvps/e1');
		expect(req.headers.get('authorization')).toBe('Bearer tok');
	});

	it('erases without throwing on a 200 status response', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ status: 'erased' }));
		await expect(eraseGuest('https://kammer.example.com', 'tok')).resolves.toBeUndefined();
	});
});
