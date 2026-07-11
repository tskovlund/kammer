import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createCommunity, fetchCommunityCreationCapability } from './api';
import { FeedApiError } from '$lib/api/errors';
import type { Instance } from '$lib/instances/types';

function instance(): Instance {
	return {
		id: 'i1',
		baseUrl: 'https://kammer.example.com',
		instanceName: 'Example',
		deviceToken: 'token-1',
		user: { id: 'u1', email: 'a@example.com', displayName: 'Alice' },
		addedAt: '2026-01-01T00:00:00Z'
	};
}

function jsonResponse(status: number, body: unknown) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

describe('communities api', () => {
	beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
	afterEach(() => vi.unstubAllGlobals());

	it('unwraps the created community from the single-object envelope', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(201, { data: { id: 'c1', name: 'Sailing', slug: 'sailing' } })
		);
		const community = await createCommunity(instance(), { name: 'Sailing', slug: 'sailing' });
		expect(community.slug).toBe('sailing');
	});

	it('maps the policy refusal to a forbidden FeedApiError', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(403, { error: { code: 'forbidden', message: 'Not allowed.' } })
		);
		const error = await createCommunity(instance(), { name: 'x', slug: 'x' }).catch((e) => e);
		expect(error).toBeInstanceOf(FeedApiError);
		expect(error.kind).toBe('forbidden');
	});

	it('reports the per-viewer creation capability, and false when the probe fails', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse(200, { can_create_community: true }));
		expect(await fetchCommunityCreationCapability(instance())).toBe(true);

		vi.mocked(fetch).mockRejectedValueOnce(new TypeError('offline'));
		expect(await fetchCommunityCreationCapability(instance())).toBe(false);
	});
});
