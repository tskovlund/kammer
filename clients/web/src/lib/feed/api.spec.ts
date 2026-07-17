import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fetchAuthedObjectUrl, uploadFile } from './api';
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

// `uploadFile` and `fetchAuthedObjectUrl` are the feed calls with a
// hand-rolled fetch + error path (multipart / blob, not the openapi-fetch
// client), so they keep their own tests. The status→kind mapping shared by
// every other call lives in `api/errors.spec`.
describe('feed uploads & authed downloads', () => {
	beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
	afterEach(() => vi.unstubAllGlobals());

	it('maps a 413 upload to a too_large error', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(errorResponse(413, 'too_large', 'Too big.'));
		const file = new File(['x'], 'big.png', { type: 'image/png' });
		await expect(uploadFile(instance(), ref, file)).rejects.toMatchObject({ kind: 'too_large' });
	});

	it('maps an authed download 401 with step_up_required to the step_up kind (#323)', async () => {
		// The account export rides this helper and is step-up-gated: its 401
		// must read as the gate, never as a dead session.
		vi.mocked(fetch).mockResolvedValueOnce(errorResponse(401, 'step_up_required'));
		await expect(fetchAuthedObjectUrl(instance(), '/api/v1/me/export')).rejects.toMatchObject({
			kind: 'step_up',
			code: 'step_up_required'
		});
	});

	it('maps a non-JSON download error body to the status kind', async () => {
		// A proxy/HTML error page carries no envelope; the body-read swallow
		// must still map the bare status, not blow up on the parse.
		vi.mocked(fetch).mockResolvedValueOnce(new Response('<html>gone</html>', { status: 404 }));
		await expect(fetchAuthedObjectUrl(instance(), '/api/v1/files/f1')).rejects.toMatchObject({
			kind: 'not_found'
		});
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
