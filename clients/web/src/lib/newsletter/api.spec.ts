import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { confirmNewsletterSubscription } from './api';

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => vi.unstubAllGlobals());

describe('confirmNewsletterSubscription', () => {
	it('posts the token and returns the confirmation', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ data: { guest_name: null, redirect_path: '/c/x/g/y' } })
		);
		const result = await confirmNewsletterSubscription('https://kammer.example.com', 'tok');
		expect(result).toEqual({ guest_name: null, redirect_path: '/c/x/g/y' });

		const [request] = vi.mocked(fetch).mock.calls[0];
		const sent = request as Request;
		expect(sent.url).toContain('/api/v1/newsletter/confirm');
		expect(await sent.clone().json()).toEqual({ token: 'tok' });
	});
});
