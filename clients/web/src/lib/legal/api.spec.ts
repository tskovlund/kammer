import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fetchLegalPage } from './api';

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => vi.unstubAllGlobals());

describe('fetchLegalPage', () => {
	it('returns the page content', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({
				data: {
					key: 'privacy',
					title: 'Privacy policy',
					content_markdown: '# Privacy',
					content_html: '<h1>Privacy</h1>',
					published: true
				}
			})
		);
		const page = await fetchLegalPage('https://kammer.example.com', 'privacy');
		expect(page.title).toBe('Privacy policy');
	});
});
