import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Instance } from '$lib/instances/types.js';
import { createDecision, fetchAssignments, respondPoll, search, ToolsApiError } from './api.js';

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

function errorResponse(status: number, code = 'error', message = 'nope') {
	return jsonResponse(status, { error: { code, message } });
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

	it('maps 403 to forbidden — a stale capability the server still refuses', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(errorResponse(403, 'forbidden', 'Not allowed.'));
		await expect(
			respondPoll(instance(), 'my-community', 'p1', { option_id: 'o1', answer: 'yes' })
		).rejects.toMatchObject({ kind: 'forbidden', status: 403 });
	});

	it('wraps a network failure rather than leaking the raw fetch rejection', async () => {
		vi.mocked(fetch).mockRejectedValueOnce(new TypeError('offline'));
		const error = await createDecision(instance(), 'my-community', 'crew', {
			title: 'Adopt bylaws'
		}).catch((cause) => cause);
		expect(error).toBeInstanceOf(ToolsApiError);
		expect(error.kind).toBe('network');
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
