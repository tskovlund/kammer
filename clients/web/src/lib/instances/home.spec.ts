import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fetchMergedHome } from './home';
import type { Instance } from './types';

function instance(overrides: Partial<Instance> = {}): Instance {
	return {
		id: 'instance-1',
		baseUrl: 'https://kammer.example.com',
		instanceName: 'Example',
		deviceToken: 'token-1',
		user: { id: 'user-1', email: 'a@example.com', displayName: 'Alice' },
		addedAt: '2026-01-01T00:00:00Z',
		...overrides
	};
}

function jsonResponse(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

const emptyHome = { upcoming_events: [], recent_activity: [] };

describe('fetchMergedHome', () => {
	beforeEach(() => {
		vi.stubGlobal('fetch', vi.fn());
	});
	afterEach(() => vi.unstubAllGlobals());

	it('returns empty results for no instances', async () => {
		const result = await fetchMergedHome([]);
		expect(result).toEqual({ upcomingEvents: [], recentActivity: [], failedInstances: [] });
	});

	it('merges and sorts events/posts across instances, tagging each with its source instance', async () => {
		const a = instance({ id: 'a', instanceName: 'A' });
		const b = instance({ id: 'b', instanceName: 'B' });

		vi.mocked(fetch)
			.mockResolvedValueOnce(
				jsonResponse({
					upcoming_events: [
						{
							id: 'e1',
							group_id: 'g1',
							title: 'Later',
							starts_at: '2026-02-01T00:00:00Z',
							all_day: false,
							timezone: 'UTC',
							rsvp_counts: { yes: 0, maybe: 0, no: 0 },
							community: { id: 'c1', name: 'C1', slug: 'c1' },
							group: { id: 'g1', name: 'G1', slug: 'g1' }
						}
					],
					recent_activity: []
				})
			)
			.mockResolvedValueOnce(
				jsonResponse({
					upcoming_events: [
						{
							id: 'e2',
							group_id: 'g2',
							title: 'Sooner',
							starts_at: '2026-01-15T00:00:00Z',
							all_day: false,
							timezone: 'UTC',
							rsvp_counts: { yes: 0, maybe: 0, no: 0 },
							community: { id: 'c2', name: 'C2', slug: 'c2' },
							group: { id: 'g2', name: 'G2', slug: 'g2' }
						}
					],
					recent_activity: []
				})
			);

		const result = await fetchMergedHome([a, b]);

		expect(result.upcomingEvents.map((event) => event.title)).toEqual(['Sooner', 'Later']);
		expect(result.upcomingEvents[0].instance.id).toBe('b');
		expect(result.failedInstances).toEqual([]);
	});

	it("surfaces an erroring instance in failedInstances without dropping the others' data", async () => {
		const ok = instance({ id: 'ok' });
		const down = instance({ id: 'down' });

		vi.mocked(fetch)
			.mockResolvedValueOnce(jsonResponse(emptyHome))
			.mockResolvedValueOnce(new Response('server error', { status: 500 }));

		const result = await fetchMergedHome([ok, down]);

		expect(result.failedInstances.map(({ instance }) => instance.id)).toEqual(['down']);
		expect(result.upcomingEvents).toEqual([]);
	});

	it('surfaces a timed-out/aborted instance in failedInstances instead of rejecting the whole call', async () => {
		const ok = instance({ id: 'ok' });
		const timedOut = instance({ id: 'timed-out' });

		vi.mocked(fetch)
			.mockResolvedValueOnce(jsonResponse(emptyHome))
			.mockRejectedValueOnce(new DOMException('The operation timed out.', 'TimeoutError'));

		const result = await fetchMergedHome([ok, timedOut]);

		expect(result.failedInstances.map(({ instance }) => instance.id)).toEqual(['timed-out']);
		expect(result.upcomingEvents).toEqual([]);
	});

	describe('failure kinds (issue #159)', () => {
		it('marks a 401 as an auth failure — the device token was revoked', async () => {
			vi.mocked(fetch).mockResolvedValueOnce(
				jsonResponse({ error: { code: 'unauthorized', message: 'Unauthorized' } }, 401)
			);

			const result = await fetchMergedHome([instance({ id: 'revoked' })]);

			expect(result.failedInstances).toEqual([
				{ instance: expect.objectContaining({ id: 'revoked' }), kind: 'auth' }
			]);
		});

		it('marks a non-401 HTTP error as a server failure', async () => {
			vi.mocked(fetch).mockResolvedValueOnce(new Response('boom', { status: 500 }));

			const result = await fetchMergedHome([instance({ id: 'broken' })]);

			expect(result.failedInstances).toEqual([
				{ instance: expect.objectContaining({ id: 'broken' }), kind: 'server' }
			]);
		});

		it('marks a rejected fetch as a network failure', async () => {
			vi.mocked(fetch).mockRejectedValueOnce(new TypeError('Failed to fetch'));

			const result = await fetchMergedHome([instance({ id: 'unreachable' })]);

			expect(result.failedInstances).toEqual([
				{ instance: expect.objectContaining({ id: 'unreachable' }), kind: 'network' }
			]);
		});
	});

	it('passes an AbortSignal to each GET call so a hung instance eventually gives up', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(jsonResponse(emptyHome));

		await fetchMergedHome([instance()]);

		const [input, init] = vi.mocked(fetch).mock.calls[0];
		// openapi-fetch may pass the signal via `init.signal` or as part of a
		// `Request` object it constructs itself — check both.
		const signal = (init as RequestInit | undefined)?.signal ?? (input as Request).signal;
		expect(signal).toBeInstanceOf(AbortSignal);
	});
});
