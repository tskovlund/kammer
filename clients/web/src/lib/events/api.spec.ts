import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	eventParamsErrorKeys,
	fetchEventIcsUrl,
	fetchEventSeries,
	fetchGroupCalendarToken,
	fetchMyCalendarToken
} from './api';
import { ApiError } from '$lib/api/errors';
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

describe('fetchEventIcsUrl', () => {
	beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
	afterEach(() => {
		vi.unstubAllGlobals();
		vi.restoreAllMocks();
	});

	it('fetches the Bearer-authenticated ICS endpoint and hands back an object URL', async () => {
		// The whole point of #307: the download must carry the device token —
		// the tokenless browser route 404s members-only events.
		vi.mocked(fetch).mockResolvedValueOnce(
			new Response('BEGIN:VCALENDAR', { headers: { 'content-type': 'text/calendar' } })
		);
		const objectUrl = vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:ics');

		await expect(fetchEventIcsUrl(instance(), 'our-club', 'e1')).resolves.toBe('blob:ics');

		const [url, init] = vi.mocked(fetch).mock.calls[0]!;
		expect(url).toBe('https://kammer.example.com/api/v1/communities/our-club/events/e1/ics');
		expect((init as RequestInit).headers).toMatchObject({ authorization: 'Bearer token-1' });
		expect(objectUrl).toHaveBeenCalledOnce();
	});
});

describe('fetchEventSeries', () => {
	beforeEach(() => vi.stubGlobal('fetch', vi.fn()));
	afterEach(() => vi.unstubAllGlobals());

	it('GETs the organizer series endpoint and unwraps the detail envelope', async () => {
		vi.mocked(fetch).mockResolvedValueOnce(
			jsonResponse({
				data: {
					series: { id: 's1', group_id: 'g1', frequency: 'weekly', until: '2026-08-01' },
					occurrences: [],
					attendance: { occurrences: [], rows: [] }
				}
			})
		);

		const result = await fetchEventSeries(instance(), 'our-club', 's1');
		expect(result.series.frequency).toBe('weekly');

		const request = vi.mocked(fetch).mock.calls[0]?.[0] as Request;
		expect(request.method).toBe('GET');
		expect(request.url).toContain('/communities/our-club/events/series/s1');
	});
});

function validation(details: Record<string, string[]>): ApiError {
	return new ApiError('validation', 'Validation failed.', 422, details);
}

describe('eventParamsErrorKeys', () => {
	it('routes each 422 field detail onto its key and suppresses the banner', () => {
		// `location_url` is the live #247 target (a non-http(s) link), `ends_at`
		// the end-before-start cross-check, and `until` the recurring-create
		// window — the last from the series changeset, not the event one.
		expect(
			eventParamsErrorKeys(
				validation({
					location_url: ['must be a valid http(s) URL'],
					ends_at: ['must be after the start'],
					until: ['must be on or after the start date']
				})
			)
		).toEqual({
			titleKey: null,
			endsAtKey: 'events.field.error.endsAt',
			locationNameKey: null,
			locationUrlKey: 'events.field.error.locationUrl',
			untilKey: 'events.field.error.until',
			bannerKind: null
		});
	});

	it('falls back to the validation banner when a 422 carries no mapped field', () => {
		expect(eventParamsErrorKeys(validation({})).bannerKind).toBe('validation');
	});

	it('falls back to the kind banner for a non-validation failure', () => {
		expect(eventParamsErrorKeys(new Error('boom')).bannerKind).toBe('server');
		expect(eventParamsErrorKeys(new ApiError('forbidden', 'no', 403)).bannerKind).toBe('forbidden');
	});
});
