import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from '$lib/feed/api.js';
import type { Instance } from '$lib/instances/types.js';
import type { EventSeriesDetail } from './types.js';

vi.mock('./api.js', async (importActual) => {
	const actual = await importActual<typeof import('./api.js')>();
	return { ...actual, fetchEventSeries: vi.fn(), setCancelled: vi.fn() };
});

import * as api from './api.js';
import { createSeriesStore } from './series-store.svelte.js';

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

function detail(overrides: Partial<EventSeriesDetail> = {}): EventSeriesDetail {
	return {
		series: { id: 's1', group_id: 'g1', frequency: 'weekly', until: '2026-08-01' },
		occurrences: [
			{
				id: 'o1',
				starts_at: '2026-06-10T10:00:00Z',
				ends_at: null,
				all_day: false,
				cancelled: false,
				rsvp_counts: { yes: 2, maybe: 1, no: 0, waitlisted: 0 }
			}
		],
		attendance: {
			occurrences: [{ id: 'o1', starts_at: '2026-06-10T10:00:00Z' }],
			rows: [{ member: { id: 'u1', display_name: 'Alice' }, statuses: ['yes'] }]
		},
		...overrides
	};
}

beforeEach(() => vi.clearAllMocks());

describe('createSeriesStore', () => {
	it('loads the organizer detail', async () => {
		vi.mocked(api.fetchEventSeries).mockResolvedValue(detail());
		const store = createSeriesStore(instance(), 'c', 's1');

		await store.load();

		expect(store.loadState).toBe('ready');
		expect(store.detail?.series.frequency).toBe('weekly');
	});

	it('surfaces a 403 as a forbidden load error, not a crash', async () => {
		vi.mocked(api.fetchEventSeries).mockRejectedValue(new ApiError('forbidden', 'Not yours.', 403));
		const store = createSeriesStore(instance(), 'c', 's1');

		await store.load();

		expect(store.loadState).toBe('error');
		expect(store.loadErrorKind).toBe('forbidden');
		expect(store.detail).toBeNull();
	});

	it('cancelling an occurrence calls setCancelled and refetches so the matrix stays true', async () => {
		const after = detail({
			occurrences: [
				{
					id: 'o1',
					starts_at: '2026-06-10T10:00:00Z',
					ends_at: null,
					all_day: false,
					cancelled: true,
					rsvp_counts: { yes: 2, maybe: 1, no: 0, waitlisted: 0 }
				}
			],
			// The cancelled occurrence has dropped out of the matrix columns.
			attendance: {
				occurrences: [],
				rows: [{ member: { id: 'u1', display_name: 'Alice' }, statuses: [] }]
			}
		});
		vi.mocked(api.fetchEventSeries).mockResolvedValueOnce(detail()).mockResolvedValueOnce(after);
		vi.mocked(api.setCancelled).mockResolvedValue({} as never);

		const store = createSeriesStore(instance(), 'c', 's1');
		await store.load();
		await store.toggleCancelled('o1', true);

		expect(api.setCancelled).toHaveBeenCalledWith(expect.anything(), 'c', 'o1', true);
		expect(store.detail?.occurrences[0].cancelled).toBe(true);
		expect(store.detail?.attendance.occurrences).toHaveLength(0);
	});

	it('surfaces a failed toggle as a dismissible action error without blanking the detail', async () => {
		vi.mocked(api.fetchEventSeries).mockResolvedValue(detail());
		vi.mocked(api.setCancelled).mockRejectedValue(new ApiError('forbidden', 'Not yours.', 403));

		const store = createSeriesStore(instance(), 'c', 's1');
		await store.load();
		await store.toggleCancelled('o1', true);

		// Only the kind is surfaced — the server's English message never is (#253).
		expect(store.actionError).toBe('forbidden');
		// The view stays put — a failed mutation never drops the loaded detail.
		expect(store.detail?.occurrences[0].cancelled).toBe(false);
		expect(store.loadState).toBe('ready');

		store.clearActionError();
		expect(store.actionError).toBeNull();
	});
});
