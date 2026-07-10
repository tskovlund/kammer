import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	PublicApiError,
	fetchPublicCommunity,
	fetchPublicGroupPosts,
	requestGuestComment,
	requestGuestRsvp
} from './api';

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => vi.unstubAllGlobals());

describe('fetchPublicCommunity', () => {
	it('returns the community and its public_listed groups', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({
				data: {
					community: { id: 'c1', name: 'Our Club', slug: 'our-club' },
					groups: [{ id: 'g1', name: 'General', slug: 'general' }]
				}
			})
		);
		const result = await fetchPublicCommunity('https://kammer.example.com', 'our-club');
		expect(result.community.name).toBe('Our Club');
		expect(result.groups).toHaveLength(1);
	});

	// `KammerWeb.Api.PublicController` answers the same neutral 404 for a
	// nonexistent community and one that exists but isn't public — this is
	// the one behaviour every public page's error state depends on.
	it('surfaces a 404 as a not_found PublicApiError', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ error: { code: 'not_found', message: 'Not found.' } }, 404)
		);
		await expect(
			fetchPublicCommunity('https://kammer.example.com', 'private-club')
		).rejects.toMatchObject({ kind: 'not_found', status: 404 });
	});
});

describe('fetchPublicGroupPosts', () => {
	it('sends the cursor as the `after` query param and returns nextCursor', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ data: [{ id: 'p2' }], next_cursor: 'cursor-2' })
		);
		const page = await fetchPublicGroupPosts(
			'https://kammer.example.com',
			'our-club',
			'general',
			'cursor-1'
		);
		expect(page.nextCursor).toBe('cursor-2');
		const [request] = vi.mocked(fetch).mock.calls[0];
		const req = request as Request;
		expect(new URL(req.url).searchParams.get('after')).toBe('cursor-1');
		// The tokenless invariant: public reads must never carry a device
		// token — a refactor that threads one through must fail here.
		expect(req.headers.get('authorization')).toBeNull();
	});
});

describe('requestGuestRsvp', () => {
	it('POSTs the guest identity and status to the tokenless guest-rsvp path', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ status: 'confirmation_sent' }, 202));
		await requestGuestRsvp(
			'https://kammer.example.com',
			'our-club',
			'e1',
			{ email: 'alice@example.com', displayName: 'Alice' },
			'yes'
		);
		const [request] = vi.mocked(fetch).mock.calls[0];
		const req = request as Request;
		expect(req.method).toBe('POST');
		expect(req.url).toBe(
			'https://kammer.example.com/api/v1/communities/our-club/events/e1/guest-rsvp'
		);
		expect(await req.clone().json()).toEqual({
			email: 'alice@example.com',
			display_name: 'Alice',
			status: 'yes'
		});
		// The tokenless invariant, write side: a guest request must never
		// carry a signed-in user's device token.
		expect(req.headers.get('authorization')).toBeNull();
	});
});

describe('requestGuestComment', () => {
	// The request endpoints are rate-limited (SPEC §3); the client needs to
	// tell that apart from a generic failure so the form can show "try
	// again later" instead of a retry-now-safe message.
	it('surfaces a 429 as a rate_limited PublicApiError', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ error: { code: 'rate_limited', message: 'Too many attempts.' } }, 429)
		);
		await expect(
			requestGuestComment(
				'https://kammer.example.com',
				'our-club',
				'general',
				'p1',
				{ email: 'alice@example.com', displayName: 'Alice' },
				'Nice post!'
			)
		).rejects.toMatchObject({ kind: 'rate_limited', status: 429 });
	});

	it('throws PublicApiError, not a raw TypeError, when the network request fails', async () => {
		vi.mocked(fetch).mockRejectedValueOnce(new TypeError('Failed to fetch'));
		await expect(
			requestGuestComment(
				'https://unreachable.example.com',
				'our-club',
				'general',
				'p1',
				{ email: 'alice@example.com', displayName: 'Alice' },
				'Nice post!'
			)
		).rejects.toThrow(PublicApiError);
	});
});
