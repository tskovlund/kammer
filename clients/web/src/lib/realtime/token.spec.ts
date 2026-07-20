import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fetchRealtimeToken } from './token';

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
afterEach(() => vi.unstubAllGlobals());

describe('fetchRealtimeToken', () => {
	it('mints a socket token, sending the device token in the Authorization header, never the URL', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({ data: { token: 'sock-123', expires_in: 60 } })
		);

		const token = await fetchRealtimeToken('https://k.example', 'device-abc');
		expect(token).toBe('sock-123');

		const request = vi.mocked(fetch).mock.calls[0]?.[0] as Request;
		expect(request.method).toBe('POST');
		expect(request.url).toBe('https://k.example/api/v1/realtime/token');
		expect(request.headers.get('authorization')).toBe('Bearer device-abc');
		// The whole point of #175: the long-lived credential rides the header,
		// never the URL a proxy could log.
		expect(request.url).not.toContain('device-abc');
	});

	it('surfaces a dead device token as a typed auth-kind ApiError', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse({ error: { code: 'unauthorized' } }, 401));

		await expect(fetchRealtimeToken('https://k.example', 'device-abc')).rejects.toMatchObject({
			kind: 'auth'
		});
	});
});
