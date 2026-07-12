import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	fetchPublicCommunity,
	fetchPublicGroupPosts,
	requestGuestComment,
	requestGuestRsvp,
	requestNewsletterSubscription
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
	it('POSTs the identity and body to the tokenless guest-comment path', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ status: 'confirmation_sent' }, 202));
		await requestGuestComment(
			'https://kammer.example.com',
			'our-club',
			'general',
			'p1',
			{ email: 'alice@example.com', displayName: 'Alice' },
			'Nice post!'
		);
		const [request] = vi.mocked(fetch).mock.calls[0];
		const req = request as Request;
		expect(req.method).toBe('POST');
		expect(req.url).toBe(
			'https://kammer.example.com/api/v1/communities/our-club/groups/general/posts/p1/guest-comment'
		);
		expect(await req.clone().json()).toEqual({
			email: 'alice@example.com',
			display_name: 'Alice',
			body_markdown: 'Nice post!'
		});
		// The tokenless invariant, write side: a guest comment request must
		// never carry a signed-in user's device token.
		expect(req.headers.get('authorization')).toBeNull();
	});
});

describe('requestNewsletterSubscription', () => {
	it('POSTs the identity and cadence to the tokenless newsletter path', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ status: 'confirmation_sent' }, 202));
		await requestNewsletterSubscription(
			'https://kammer.example.com',
			'our-club',
			'general',
			{ email: 'alice@example.com', displayName: 'Alice' },
			'weekly'
		);
		const [request] = vi.mocked(fetch).mock.calls[0];
		const req = request as Request;
		expect(req.method).toBe('POST');
		expect(req.url).toBe(
			'https://kammer.example.com/api/v1/communities/our-club/groups/general/newsletter'
		);
		expect(await req.clone().json()).toEqual({
			email: 'alice@example.com',
			display_name: 'Alice',
			cadence: 'weekly'
		});
		// Tokenless like every other public request: no device token rides
		// along with an anonymous subscription.
		expect(req.headers.get('authorization')).toBeNull();
	});
});
