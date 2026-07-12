import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fetchGroupCalendarToken, fetchMyCalendarToken } from './api';
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

function jsonResponse(body: unknown) {
	return new Response(JSON.stringify(body), {
		status: 200,
		headers: { 'content-type': 'application/json' }
	});
}

describe('calendar subscription tokens', () => {
	beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
	afterEach(() => vi.unstubAllGlobals());

	it('fetchMyCalendarToken GETs the personal endpoint and unwraps the token + url', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({
				data: { token: 'tok', url: 'https://kammer.example.com/calendar/user/tok.ics' }
			})
		);

		const result = await fetchMyCalendarToken(instance());
		expect(result.url).toBe('https://kammer.example.com/calendar/user/tok.ics');

		const request = vi.mocked(fetch).mock.calls[0]?.[0] as Request;
		expect(request.method).toBe('GET');
		expect(request.url).toContain('/api/v1/me/calendar-token');
	});

	it('fetchGroupCalendarToken addresses the group-scoped endpoint', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({
				data: { token: 'gtok', url: 'https://kammer.example.com/calendar/group/gtok.ics' }
			})
		);

		const result = await fetchGroupCalendarToken(instance(), 'our-club', 'brass');
		expect(result.token).toBe('gtok');

		const request = vi.mocked(fetch).mock.calls[0]?.[0] as Request;
		expect(request.url).toContain('/communities/our-club/groups/brass/calendar-token');
	});
});
