import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { uploadFile } from './api';
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

const ref = { community: 'my-community', group: 'my-group' };

function errorResponse(status: number, code = 'error', message = 'nope') {
	return new Response(JSON.stringify({ error: { code, message } }), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

// `uploadFile` is the one feed call with a hand-rolled fetch + error path
// (multipart, not the openapi-fetch client), so it keeps its own tests. The
// status→kind mapping shared by every other call lives in `api/errors.spec`.
describe('feed uploads', () => {
	beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
	afterEach(() => vi.unstubAllGlobals());

	it('maps a 413 upload to a too_large error', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(errorResponse(413, 'too_large', 'Too big.'));
		const file = new File(['x'], 'big.png', { type: 'image/png' });
		await expect(uploadFile(instance(), ref, file)).rejects.toMatchObject({ kind: 'too_large' });
	});

	it('sends the upload as multipart with the Bearer token', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			new Response(JSON.stringify({ data: { id: 'f1' } }), {
				status: 201,
				headers: { 'content-type': 'application/json' }
			})
		);
		const file = new File(['x'], 'photo.png', { type: 'image/png' });
		await uploadFile(instance(), ref, file);

		const [url, init] = vi.mocked(fetch).mock.calls[0];
		expect(String(url)).toContain('/communities/my-community/groups/my-group/uploads');
		expect((init as RequestInit).method).toBe('POST');
		expect((init as RequestInit).body).toBeInstanceOf(FormData);
		const headers = new Headers((init as RequestInit).headers);
		expect(headers.get('authorization')).toBe('Bearer token-1');
	});
});
