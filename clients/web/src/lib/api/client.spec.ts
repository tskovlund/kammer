import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createApiClient } from './client';

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

/**
 * openapi-fetch may hand the underlying fetch either (url, init) or a
 * single Request it constructed — normalize both shapes.
 */
function lastRequest() {
	const [input, init] = vi.mocked(fetch).mock.calls[0];
	if (input instanceof Request) {
		return { url: input.url, headers: input.headers };
	}
	return { url: String(input), headers: new Headers((init as RequestInit | undefined)?.headers) };
}

describe('createApiClient', () => {
	beforeEach(() => {
		vi.stubGlobal('fetch', vi.fn().mockResolvedValue(jsonResponse({})));
	});
	afterEach(() => vi.unstubAllGlobals());

	it('sends requests to the given instance base URL', async () => {
		const client = createApiClient('https://kammer.example.com');
		await client.GET('/api/v1/instance');

		expect(lastRequest().url).toBe('https://kammer.example.com/api/v1/instance');
	});

	it('attaches the device token as an Authorization: Bearer header on authenticated calls', async () => {
		const client = createApiClient('https://kammer.example.com', 'device-token-123');
		await client.GET('/api/v1/home');

		expect(lastRequest().headers.get('authorization')).toBe('Bearer device-token-123');
	});

	it('sends no Authorization header when constructed without a device token', async () => {
		const client = createApiClient('https://kammer.example.com');
		await client.GET('/api/v1/instance');

		expect(lastRequest().headers.get('authorization')).toBeNull();
	});
});
