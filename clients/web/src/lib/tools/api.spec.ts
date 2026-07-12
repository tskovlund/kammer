import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Instance } from '$lib/instances/types.js';
import { fetchAssignments, search } from './api.js';

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

describe('tools api', () => {
	beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
	afterEach(() => vi.unstubAllGlobals());

	it('unwraps the data envelope for the assignment list', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(200, { data: [{ id: 'a1', title: 'Bring cake' }] })
		);
		const list = await fetchAssignments(instance(), 'my-community', 'crew');
		expect(list).toHaveLength(1);
		expect(list[0]?.id).toBe('a1');
	});

	it('passes the query as the `q` parameter', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse(200, { data: { posts: [], comments: [], events: [], files: [] } })
		);
		await search(instance(), 'my-community', 'picnic');
		const request = vi.mocked(fetch).mock.calls[0][0] as Request;
		expect(request.url).toContain('/communities/my-community/search');
		expect(request.url).toContain('q=picnic');
	});
});
