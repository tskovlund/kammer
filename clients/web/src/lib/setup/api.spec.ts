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

	it('rejects with a validation SetupApiError on 422', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ error: { code: 'validation', message: 'slug has already been taken' } }, 422)
		);
		await expect(
			completeSetup('https://kammer.example.com', {
				token: 'setup-tok',
				operator: { email: 'op@example.com' },
				instance: {},
				community: { name: 'Our Club', slug: 'taken' },
				group: { name: 'General', slug: 'general' }
			})
		).rejects.toMatchObject({ kind: 'validation' });
	});

	// There is deliberately no separate `/setup/verify-token` endpoint
	// (issue #230) — a boolean oracle over the setup credential — so a bad
	// or already-consumed token is only discovered here, on the real
	// completion attempt, as a neutral `forbidden` (403).
	it('rejects with a forbidden SetupApiError on 403 for a bad or expired token', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ error: { code: 'forbidden', message: 'Setup is not available.' } }, 403)
		);
		await expect(
			completeSetup('https://kammer.example.com', {
				token: 'wrong-token',
				operator: { email: 'op@example.com' },
				instance: {},
				community: { name: 'Our Club', slug: 'our-club' },
				group: { name: 'General', slug: 'general' }
			})
		).rejects.toMatchObject({ kind: 'forbidden', status: 403 });
	});
});
