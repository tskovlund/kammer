import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { completeSetup, fetchSetupStatus } from './api';

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => vi.unstubAllGlobals());

describe('fetchSetupStatus', () => {
	it('returns whether setup has completed', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ setup_completed: true }));
		await expect(fetchSetupStatus('https://kammer.example.com')).resolves.toBe(true);
	});
});

describe('completeSetup', () => {
	it('posts the full wizard payload and returns the completed instance', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(
				{
					data: {
						community_slug: 'our-club',
						group_slug: 'general',
						invite_token: 'itok',
						invite_url: 'https://kammer.example.com/invite/itok',
						magic_link_sent: true
					}
				},
				201
			)
		);
		const result = await completeSetup('https://kammer.example.com', {
			token: 'setup-tok',
			operator: { email: 'op@example.com', display_name: 'Op' },
			instance: {
				instance_name: 'Kammer',
				default_locale: 'en',
				community_creation_policy: 'operators_only'
			},
			community: { name: 'Our Club', slug: 'our-club', accent_color: '#3E6B48' },
			group: { name: 'General', slug: 'general' },
			demo_data: false
		});
		expect(result.community_slug).toBe('our-club');
		expect(result.magic_link_sent).toBe(true);
	});
});
