import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPost, ApiError, uploadFile } from './api';
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

describe('feed api error mapping', () => {
	beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
	afterEach(() => vi.unstubAllGlobals());

	it('maps 422 to a validation error and surfaces the server message', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			errorResponse(422, 'unprocessable', 'Body is required.')
		);
		await expect(createPost(instance(), ref, { body_markdown: '' })).rejects.toMatchObject({
			kind: 'validation',
			message: 'Body is required.',
			status: 422
		});
	});

	it('maps 403 to a forbidden error', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(errorResponse(403, 'forbidden', 'Not allowed.'));
		await expect(createPost(instance(), ref, { body_markdown: 'x' })).rejects.toMatchObject({
			kind: 'forbidden'
		});
	});

	it('maps 401 to an auth error so the instance can be re-signed-in', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(errorResponse(401));
		await expect(createPost(instance(), ref, { body_markdown: 'x' })).rejects.toMatchObject({
			kind: 'auth'
		});
	});

	it('maps 429 to a rate-limited error', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(errorResponse(429));
		await expect(createPost(instance(), ref, { body_markdown: 'x' })).rejects.toMatchObject({
			kind: 'rate_limited'
		});
	});

	it('treats a rejected fetch as a network error', async () => {
		vi.mocked(fetch).mockRejectedValueOnce(new TypeError('Failed to fetch'));
		const error = await createPost(instance(), ref, { body_markdown: 'x' }).catch((e) => e);
		expect(error).toBeInstanceOf(ApiError);
		expect(error.kind).toBe('network');
	});

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
